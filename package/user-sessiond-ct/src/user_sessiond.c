/* user_sessiond-ct: ubus user_session backed by nf_conntrack + ARP
 * Drop-in for FanchmWrt UserSession when fwx_user.ko is empty under UA3F TPROXY.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <time.h>
#include <sys/time.h>

#include <libubox/uloop.h>
#include <libubox/blobmsg_json.h>
#include <libubus.h>

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#endif

#define MAX_CLIENTS 256
#define MAX_SESSIONS 4096
#define HIST_LEN 1440
#define ARP_MAX 256

struct client_stat {
	char mac[32];
	char ip[64];
	int online;
	int session_count;
	int tcp_count;
	int udp_count;
	int other_count;
	int last_seen;
};

struct session_row {
	char src_ip[64];
	int src_port;
	char dst_ip[64];
	int dst_port;
	int proto; /* 6 tcp, 17 udp, 0 other */
	unsigned long up_bytes;
	unsigned long down_bytes;
	char state[32];
	char app_name[128];
	char url[256];
};

struct app_entry {
	char mac[32];
	char src_ip[64];
	int src_port;
	char dst_ip[64];
	int dst_port;
	char app_name[128];
	char url[256];
};

#define MAX_APPS 2048
static struct app_entry apps[MAX_APPS];
static int n_apps;

static void mac_norm(const char *in, char *out, size_t n);

static void load_apps(void)
{
	FILE *f = fopen("/proc/net/af_active_app", "r");
	char line[1024];
	n_apps = 0;
	if (!f)
		return;
	if (!fgets(line, sizeof(line), f)) {
		fclose(f);
		return;
	}
	while (fgets(line, sizeof(line), f) && n_apps < MAX_APPS) {
		unsigned appid = 0;
		char mac[32], sip[64], dip[64], host[128], uri[256];
		int sport = 0, dport = 0;
		memset(host, 0, sizeof(host));
		memset(uri, 0, sizeof(uri));
		if (sscanf(line, "%u %31s %63s %d %63s %d",
			   &appid, mac, sip, &sport, dip, &dport) < 6)
			continue;
		/* Host is a domain-like token; URI starts with / */
		char *p;
		for (p = line; *p; p++) {
			if (*p == '/' && p > line && p[-1] == ' ') {
				sscanf(p, "%255s", uri);
				break;
			}
		}
		/* pick last token that looks like a hostname (has a dot, no /) */
		{
			char *tok, *save = NULL;
			char buf[1024];
			snprintf(buf, sizeof(buf), "%s", line);
			for (tok = strtok_r(buf, " \t\n", &save); tok;
			     tok = strtok_r(NULL, " \t\n", &save)) {
				if (strchr(tok, '.') && !strchr(tok, '/') &&
				    !isdigit((unsigned char)tok[0])) {
					snprintf(host, sizeof(host), "%s", tok);
				}
			}
		}
		struct app_entry *e = &apps[n_apps++];
		mac_norm(mac, e->mac, sizeof(e->mac));
		snprintf(e->src_ip, sizeof(e->src_ip), "%s", sip);
		e->src_port = sport;
		snprintf(e->dst_ip, sizeof(e->dst_ip), "%s", dip);
		e->dst_port = dport;
		if (host[0])
			snprintf(e->app_name, sizeof(e->app_name), "%s", host);
		else
			snprintf(e->app_name, sizeof(e->app_name), "App %u", appid);
		if (uri[0])
			snprintf(e->url, sizeof(e->url), "%s", uri);
		else
			snprintf(e->url, sizeof(e->url), "%s", host);
	}
	fclose(f);
}

static struct app_entry *find_app(const char *mac, const char *sip, int sport,
				  const char *dip, int dport)
{
	for (int i = 0; i < n_apps; i++) {
		if (apps[i].src_port == sport && apps[i].dst_port == dport &&
		    strcmp(apps[i].mac, mac) == 0 &&
		    strcmp(apps[i].src_ip, sip) == 0 &&
		    strcmp(apps[i].dst_ip, dip) == 0)
			return &apps[i];
	}
	return NULL;
}

struct hist_point {
	int total, tcp, udp, other;
};

struct client_hist {
	char mac[32];
	int used;
	struct hist_point ring[HIST_LEN];
	int head; /* next write */
	int count;
};

static struct client_stat clients[MAX_CLIENTS];
static int n_clients;
static struct client_hist hists[MAX_CLIENTS];
static struct ubus_context *ctx;
static struct blob_buf bb;
static int sample_sec = 5;
static int snap_ttl_sec = 2;
static time_t snap_ts;
static int snap_valid;

static int parse_arp(void);
static void scan_conntrack(const char *filter_mac, struct session_row *rows, int max_rows, int *out_rows);

static void refresh_snapshot(void)
{
	time_t now = time(NULL);
	if (snap_valid && (now - snap_ts) < snap_ttl_sec)
		return;
	parse_arp();
	scan_conntrack(NULL, NULL, 0, NULL);
	snap_ts = now;
	snap_valid = 1;
}

static void mac_norm(const char *in, char *out, size_t n)
{
	size_t j = 0;
	for (size_t i = 0; in[i] && j + 1 < n; i++) {
		unsigned char c = (unsigned char)in[i];
		if (c == '-') {
			out[j++] = ':';
		} else {
			out[j++] = (char)tolower(c);
		}
	}
	out[j] = 0;
}

static int parse_arp(void)
{
	FILE *f = fopen("/proc/net/arp", "r");
	char line[256];
	n_clients = 0;
	if (!f)
		return -1;
	if (!fgets(line, sizeof(line), f)) {
		fclose(f);
		return -1;
	}
	while (fgets(line, sizeof(line), f) && n_clients < MAX_CLIENTS) {
		char ip[64], mac[32], dev[32];
		int type, flags;
		if (sscanf(line, "%63s 0x%x 0x%x %31s %*s %31s",
			   ip, &type, &flags, mac, dev) < 5)
			continue;
		if (strcmp(mac, "00:00:00:00:00:00") == 0)
			continue;
		/* skip incomplete */
		if (!(flags & 0x2))
			continue;
		struct client_stat *c = &clients[n_clients];
		memset(c, 0, sizeof(*c));
		mac_norm(mac, c->mac, sizeof(c->mac));
		snprintf(c->ip, sizeof(c->ip), "%s", ip);
		c->online = 1;
		c->last_seen = (int)time(NULL);
		n_clients++;
	}
	fclose(f);
	return 0;
}

static struct client_stat *find_by_ip(const char *ip)
{
	for (int i = 0; i < n_clients; i++)
		if (strcmp(clients[i].ip, ip) == 0)
			return &clients[i];
	return NULL;
}

static struct client_stat *find_by_mac(const char *mac)
{
	for (int i = 0; i < n_clients; i++)
		if (strcmp(clients[i].mac, mac) == 0)
			return &clients[i];
	return NULL;
}

static struct client_hist *hist_for(const char *mac)
{
	for (int i = 0; i < MAX_CLIENTS; i++) {
		if (hists[i].used && strcmp(hists[i].mac, mac) == 0)
			return &hists[i];
	}
	for (int i = 0; i < MAX_CLIENTS; i++) {
		if (!hists[i].used) {
			size_t n = strlen(mac);
			if (n >= sizeof(hists[i].mac))
				n = sizeof(hists[i].mac) - 1;
			hists[i].used = 1;
			memcpy(hists[i].mac, mac, n);
			hists[i].mac[n] = 0;
			return &hists[i];
		}
	}
	return NULL;
}

/* count sessions per client from conntrack; optionally collect list for one MAC */
static void scan_conntrack(const char *filter_mac, struct session_row *rows, int max_rows, int *out_rows)
{
	FILE *f = fopen("/proc/net/nf_conntrack", "r");
	char line[1024];
	if (out_rows)
		*out_rows = 0;
	load_apps();
	if (!f)
		return;
	for (int i = 0; i < n_clients; i++) {
		clients[i].session_count = 0;
		clients[i].tcp_count = 0;
		clients[i].udp_count = 0;
		clients[i].other_count = 0;
	}
	while (fgets(line, sizeof(line), f)) {
		char src[64] = "", dst[64] = "";
		int sport = 0, dport = 0;
		int proto = 0;
		unsigned long bytes_in = 0, bytes_out = 0;
		char state[32] = "";
		char *p;

		/* proto number: "ipv4     2 tcp" or udp/icmp/unknown */
		p = strstr(line, " tcp ");
		if (p) {
			proto = 6;
			p += 5;
		} else if ((p = strstr(line, " udp "))) {
			proto = 17;
			p += 5;
		} else {
			proto = 0;
			p = line;
		}

		char *ss = strstr(line, "src=");
		char *sd = strstr(line, "dst=");
		if (!ss || !sd)
			continue;
		sscanf(ss, "src=%63s", src);
		sscanf(sd, "dst=%63s", dst);
		char *sp = strstr(line, "sport=");
		char *dp = strstr(line, "dport=");
		if (sp)
			sport = atoi(sp + 6);
		if (dp)
			dport = atoi(dp + 6);

		/* pick original direction bytes: first bytes= after first src= */
		char *b1 = strstr(line, "bytes=");
		if (b1)
			bytes_out = strtoul(b1 + 6, NULL, 10);
		/* reply direction: second src= block */
		char *src2 = strstr(ss + 4, "src=");
		if (src2) {
			char *b2 = strstr(src2, "bytes=");
			if (b2)
				bytes_in = strtoul(b2 + 6, NULL, 10);
		}

		if (strstr(line, "ESTABLISHED"))
			snprintf(state, sizeof(state), "ESTABLISHED");
		else if (strstr(line, "TIME_WAIT"))
			snprintf(state, sizeof(state), "TIME_WAIT");
		else if (strstr(line, "SYN_SENT"))
			snprintf(state, sizeof(state), "SYN_SENT");
		else if (strstr(line, "CLOSE_WAIT"))
			snprintf(state, sizeof(state), "CLOSE_WAIT");
		else
			snprintf(state, sizeof(state), "-");

		struct client_stat *c = find_by_ip(src);
		/* also match if this is reply and orig src is LAN (already handled by first src=) */
		if (c) {
			c->session_count++;
			if (proto == 6)
				c->tcp_count++;
			else if (proto == 17)
				c->udp_count++;
			else
				c->other_count++;
			if (rows && filter_mac && strcmp(c->mac, filter_mac) == 0 &&
			    *out_rows < max_rows) {
				struct session_row *r = &rows[*out_rows];
				memset(r, 0, sizeof(*r));
				snprintf(r->src_ip, sizeof(r->src_ip), "%s", src);
				r->src_port = sport;
				snprintf(r->dst_ip, sizeof(r->dst_ip), "%s", dst);
				r->dst_port = dport;
				r->proto = proto;
				r->up_bytes = bytes_out;
				r->down_bytes = bytes_in;
				snprintf(r->state, sizeof(r->state), "%s", state);
				{
					struct app_entry *ae = find_app(c->mac, src, sport, dst, dport);
					if (ae) {
						snprintf(r->app_name, sizeof(r->app_name), "%s", ae->app_name);
						snprintf(r->url, sizeof(r->url), "%s", ae->url);
					} else {
						snprintf(r->app_name, sizeof(r->app_name), "-");
						r->url[0] = 0;
					}
				}
				(*out_rows)++;
			}
		}
	}
	fclose(f);
}

static void sample_history(void)
{
	parse_arp();
	scan_conntrack(NULL, NULL, 0, NULL);
	for (int i = 0; i < n_clients; i++) {
		struct client_hist *h = hist_for(clients[i].mac);
		if (!h)
			continue;
		struct hist_point *pt = &h->ring[h->head];
		pt->total = clients[i].session_count;
		pt->tcp = clients[i].tcp_count;
		pt->udp = clients[i].udp_count;
		pt->other = clients[i].other_count;
		h->head = (h->head + 1) % HIST_LEN;
		if (h->count < HIST_LEN)
			h->count++;
	}
}

static struct uloop_timeout sample_tm;

static void sample_cb(struct uloop_timeout *t)
{
	sample_history();
	uloop_timeout_set(t, sample_sec * 1000);
}

static void hist_fill(struct blob_buf *b, const char *name, struct client_hist *h,
		      int range, int step_sec, const char *field)
{
	/* range: 1=5min, 2=hourish, 3=day — map to how many samples */
	int want;
	if (range == 1)
		want = (5 * 60) / step_sec;
	else if (range == 3)
		want = (24 * 3600) / step_sec;
	else
		want = (2 * 3600) / step_sec;
	if (want > HIST_LEN)
		want = HIST_LEN;
	if (want < 1)
		want = 1;
	/* cap for UI similar to original ~10-60 points */
	if (want > 60 && range != 3)
		want = 60;
	if (want > 120)
		want = 120;

	void *arr = blobmsg_open_array(b, name);
	int got = 0;
	int sum = 0, peak = 0, last = 0;
	/* walk from oldest among last `want` samples */
	int n = h ? h->count : 0;
	if (n > want)
		n = want;
	int start = h ? ((h->head - n + HIST_LEN * 2) % HIST_LEN) : 0;
	for (int i = 0; i < n; i++) {
		struct hist_point *pt = &h->ring[(start + i) % HIST_LEN];
		int v = 0;
		if (strcmp(field, "tcp") == 0)
			v = pt->tcp;
		else if (strcmp(field, "udp") == 0)
			v = pt->udp;
		else if (strcmp(field, "other") == 0)
			v = pt->other;
		else
			v = pt->total;
		blobmsg_add_u32(b, NULL, v);
		sum += v;
		if (v > peak)
			peak = v;
		last = v;
		got++;
	}
	blobmsg_close_array(b, arr);
	(void)sum;
	(void)peak;
	(void)last;
	(void)got;
}

static int hist_avg_peak(struct client_hist *h, int range, int step_sec,
			 int *avg, int *peak, int *cur)
{
	int want;
	if (range == 1)
		want = (5 * 60) / step_sec;
	else if (range == 3)
		want = (24 * 3600) / step_sec;
	else
		want = (2 * 3600) / step_sec;
	if (want > 60 && range != 3)
		want = 60;
	if (want > 120)
		want = 120;
	int n = h ? h->count : 0;
	if (n > want)
		n = want;
	*avg = 0;
	*peak = 0;
	*cur = 0;
	if (!h || n <= 0)
		return 0;
	int start = (h->head - n + HIST_LEN * 2) % HIST_LEN;
	int sum = 0;
	for (int i = 0; i < n; i++) {
		int v = h->ring[(start + i) % HIST_LEN].total;
		sum += v;
		if (v > *peak)
			*peak = v;
		if (i == n - 1)
			*cur = v;
	}
	*avg = sum / n;
	return n;
}

enum {
	L_API,
	L_DATA,
	__L_MAX
};

static const struct blobmsg_policy listen_policy[__L_MAX] = {
	[L_API] = { .name = "api", .type = BLOBMSG_TYPE_STRING },
	[L_DATA] = { .name = "data", .type = BLOBMSG_TYPE_TABLE },
};

static int handle_common(struct ubus_context *c, struct ubus_object *obj,
			 struct ubus_request_data *req, const char *method,
			 struct blob_attr *msg)
{
	struct blob_attr *tb[__L_MAX];
	blobmsg_parse(listen_policy, __L_MAX, tb, blob_data(msg), blob_len(msg));
	const char *api = tb[L_API] ? blobmsg_get_string(tb[L_API]) : "";
	struct blob_attr *data = tb[L_DATA];

	blob_buf_init(&bb, 0);
	blobmsg_add_u32(&bb, "code", 2000);
	blobmsg_add_string(&bb, "msg", "ok");

	void *droot = blobmsg_open_table(&bb, "data");

	if (strcmp(api, "get_session_user_list") == 0) {
		refresh_snapshot();
		int total = 0;
		void *arr = blobmsg_open_array(&bb, "list");
		for (int i = 0; i < n_clients; i++) {
			void *t = blobmsg_open_table(&bb, NULL);
			blobmsg_add_string(&bb, "mac", clients[i].mac);
			blobmsg_add_string(&bb, "hostname", "");
			blobmsg_add_string(&bb, "nickname", "");
			blobmsg_add_u32(&bb, "online", clients[i].online);
			blobmsg_add_u32(&bb, "session_count", clients[i].session_count);
			blobmsg_add_u32(&bb, "tcp_count", clients[i].tcp_count);
			blobmsg_add_u32(&bb, "udp_count", clients[i].udp_count);
			blobmsg_add_u32(&bb, "other_count", clients[i].other_count);
			blobmsg_close_table(&bb, t);
			total++;
		}
		blobmsg_close_array(&bb, arr);
		blobmsg_add_u32(&bb, "total_num", total);
	} else if (strcmp(api, "get_session_history") == 0) {
		const char *mac = "";
		int range = 2;
		if (data) {
			enum { D_MAC, D_RANGE, __D_MAX };
			static const struct blobmsg_policy dp[__D_MAX] = {
				[D_MAC] = { .name = "mac", .type = BLOBMSG_TYPE_STRING },
				[D_RANGE] = { .name = "range", .type = BLOBMSG_TYPE_INT32 },
			};
			struct blob_attr *dt[__D_MAX] = {0};
			blobmsg_parse(dp, __D_MAX, dt, blobmsg_data(data), blobmsg_data_len(data));
			if (dt[D_MAC])
				mac = blobmsg_get_string(dt[D_MAC]);
			if (dt[D_RANGE])
				range = blobmsg_get_u32(dt[D_RANGE]);
		}
		if (range != 1 && range != 2 && range != 3)
			range = 2;
		int step_sec = (range == 1) ? 5 : 60;
		refresh_snapshot();
		struct client_stat *c = find_by_mac(mac);
		struct client_hist *h = NULL;
		for (int i = 0; i < MAX_CLIENTS; i++)
			if (hists[i].used && strcmp(hists[i].mac, mac) == 0)
				h = &hists[i];
		int avg = 0, peak = 0, cur = 0;
		hist_avg_peak(h, range, step_sec, &avg, &peak, &cur);
		blobmsg_add_string(&bb, "mac", mac);
		blobmsg_add_string(&bb, "hostname", "");
		blobmsg_add_u32(&bb, "online", c ? c->online : 0);
		blobmsg_add_u32(&bb, "range", range);
		blobmsg_add_u32(&bb, "step_sec", step_sec);
		blobmsg_add_u32(&bb, "current", cur);
		blobmsg_add_u32(&bb, "avg", avg);
		blobmsg_add_u32(&bb, "peak", peak);
		hist_fill(&bb, "list", h, range, step_sec, "total");
		hist_fill(&bb, "tcp_list", h, range, step_sec, "tcp");
		hist_fill(&bb, "udp_list", h, range, step_sec, "udp");
		hist_fill(&bb, "other_list", h, range, step_sec, "other");
	} else if (strcmp(api, "get_session_detail") == 0) {
		const char *mac = "";
		int page = 1, page_size = 20;
		if (data) {
			enum { D_MAC, D_PAGE, D_PS, __D_MAX2 };
			static const struct blobmsg_policy dp[__D_MAX2] = {
				[D_MAC] = { .name = "mac", .type = BLOBMSG_TYPE_STRING },
				[D_PAGE] = { .name = "page", .type = BLOBMSG_TYPE_INT32 },
				[D_PS] = { .name = "page_size", .type = BLOBMSG_TYPE_INT32 },
			};
			struct blob_attr *dt[__D_MAX2] = {0};
			blobmsg_parse(dp, __D_MAX2, dt, blobmsg_data(data), blobmsg_data_len(data));
			if (dt[D_MAC])
				mac = blobmsg_get_string(dt[D_MAC]);
			if (dt[D_PAGE])
				page = blobmsg_get_u32(dt[D_PAGE]);
			if (dt[D_PS])
				page_size = blobmsg_get_u32(dt[D_PS]);
		}
		if (page < 1)
			page = 1;
		if (page_size < 1)
			page_size = 20;
		if (page_size > 200)
			page_size = 200;
		refresh_snapshot();
		static struct session_row rows[MAX_SESSIONS];
		int nrows = 0;
		scan_conntrack(mac, rows, MAX_SESSIONS, &nrows);
		int total_page = (nrows + page_size - 1) / page_size;
		if (total_page < 1)
			total_page = 1;
		int start = (page - 1) * page_size;
		void *arr = blobmsg_open_array(&bb, "list");
		for (int i = start; i < nrows && i < start + page_size; i++) {
			void *t = blobmsg_open_table(&bb, NULL);
			blobmsg_add_string(&bb, "mac", mac);
			blobmsg_add_string(&bb, "src_ip", rows[i].src_ip);
			blobmsg_add_u32(&bb, "src_port", rows[i].src_port);
			blobmsg_add_string(&bb, "dst_ip", rows[i].dst_ip);
			blobmsg_add_u32(&bb, "dst_port", rows[i].dst_port);
			blobmsg_add_string(&bb, "proto",
					   rows[i].proto == 6 ? "TCP" :
					   rows[i].proto == 17 ? "UDP" : "OTHER");
			blobmsg_add_u64(&bb, "up_bytes", rows[i].up_bytes);
			blobmsg_add_u64(&bb, "down_bytes", rows[i].down_bytes);
			blobmsg_add_string(&bb, "state", rows[i].state);
			blobmsg_add_string(&bb, "app_name", rows[i].app_name);
			blobmsg_add_string(&bb, "url", rows[i].url);
			blobmsg_close_table(&bb, t);
		}
		blobmsg_close_array(&bb, arr);
		blobmsg_add_u32(&bb, "total_num", nrows);
		blobmsg_add_u32(&bb, "page", page);
		blobmsg_add_u32(&bb, "page_size", page_size);
		blobmsg_add_u32(&bb, "total_page", total_page);
	} else {
		blobmsg_add_u32(&bb, "code", 4000);
		blobmsg_add_string(&bb, "msg", "unknown api");
		blobmsg_close_table(&bb, droot);
		return ubus_send_reply(ctx, req, bb.head);
	}

	blobmsg_close_table(&bb, droot);
	return ubus_send_reply(ctx, req, bb.head);
}

static const struct ubus_method user_session_methods[] = {
	UBUS_METHOD("common", handle_common, listen_policy),
};

static struct ubus_object_type user_session_type =
	UBUS_OBJECT_TYPE("user_session", user_session_methods);

static struct ubus_object user_session_obj = {
	.name = "user_session",
	.type = &user_session_type,
	.methods = user_session_methods,
	.n_methods = ARRAY_SIZE(user_session_methods),
};

int main(int argc, char **argv)
{
	uloop_init();
	ctx = ubus_connect("/var/run/ubus/ubus.sock");
	if (!ctx) {
		fprintf(stderr, "ubus connect failed\n");
		return 1;
	}
	ubus_add_uloop(ctx);
	if (ubus_add_object(ctx, &user_session_obj)) {
		fprintf(stderr, "ubus add object failed\n");
		return 1;
	}
	sample_cb(&sample_tm);
	uloop_timeout_set(&sample_tm, sample_sec * 1000);
	fprintf(stderr, "user_sessiond-ct started (conntrack mode)\n");
	uloop_run();
	ubus_free(ctx);
	uloop_done();
	return 0;
}
