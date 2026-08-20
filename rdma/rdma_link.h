#pragma once
//
// rdma_link.h — the connection plumbing shared by the Phase 2 sender and
// receiver.  No CUDA in here, because the PXI side has no CUDA to link against.
//
// WHY RAW VERBS AND A TCP SIDE CHANNEL RATHER THAN rdma_cm
// The plan says "standard RDMA connection manager setup".  We use raw verbs
// with a TCP out-of-band exchange instead, for one reason: this is exactly the
// path perftest takes, and perftest is the only RDMA traffic that has ever been
// demonstrated to work between these two boxes (Gate 3, 694.76 us for a 4 MB
// write at 98% of line rate).  Adopting the proven path means a failure here is
// a bug in our code rather than an unexplored interaction with rdma_cm on an NI
// Linux RT kernel.  rdma_cm remains available if Phase 3 wants it.
//
// The TCP channel carries three things and nothing else: the one-time QP
// parameter exchange at startup, the one-time pool geometry, and a per-message
// credit.  It is never on any path we intend to measure.

#include <infiniband/verbs.h>

#include <arpa/inet.h>
#include <endian.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace rdma {

// ─────────────────────────────────────────────────────────────────────────────
// Failure handling
//
// Every one of these is a startup-time or protocol-level failure.  There is no
// sensible partial-success mode for "the queue pair would not reach RTS", and a
// half-connected QP that silently drops work requests is precisely the kind of
// thing that produces a plausible-looking wrong answer.  So they abort loudly.
// ─────────────────────────────────────────────────────────────────────────────
[[noreturn]] inline void die(const char* what) {
    std::fprintf(stderr, "\nFATAL: %s: %s\n", what, std::strerror(errno));
    std::exit(2);
}

[[noreturn]] inline void die_msg(const char* what) {
    std::fprintf(stderr, "\nFATAL: %s\n", what);
    std::exit(2);
}

#define RDMA_CHECK(cond, msg) \
    do { if (!(cond)) rdma::die_msg(msg); } while (0)

// ─────────────────────────────────────────────────────────────────────────────
// What the two sides tell each other, once, at startup.
//
// Sent as fixed-width big-endian so that the aarch64 Spark and the x86_64 PXI
// agree without a serialisation library.  Both happen to be little-endian, but
// relying on that is how a byte-order bug waits three years to appear.
// ─────────────────────────────────────────────────────────────────────────────
struct WireInfo {
    uint32_t qpn;          // queue pair number to send to
    uint32_t psn;          // starting packet sequence number
    uint32_t rkey;         // remote key for the receive pool
    uint32_t n_slots;      // slots in the receive pool
    uint64_t pool_addr;    // virtual address of slot 0 on the receiver
    uint64_t slot_bytes;   // stride between slots
    uint8_t  gid[16];      // RoCEv2 requires a GID; there are no LIDs here
};

inline void hton_wire(WireInfo& w) {
    w.qpn        = htonl(w.qpn);
    w.psn        = htonl(w.psn);
    w.rkey       = htonl(w.rkey);
    w.n_slots    = htonl(w.n_slots);
    w.pool_addr  = htobe64(w.pool_addr);
    w.slot_bytes = htobe64(w.slot_bytes);
}

inline void ntoh_wire(WireInfo& w) {
    w.qpn        = ntohl(w.qpn);
    w.psn        = ntohl(w.psn);
    w.rkey       = ntohl(w.rkey);
    w.n_slots    = ntohl(w.n_slots);
    w.pool_addr  = be64toh(w.pool_addr);
    w.slot_bytes = be64toh(w.slot_bytes);
}

// ─────────────────────────────────────────────────────────────────────────────
// TCP side channel
// ─────────────────────────────────────────────────────────────────────────────
inline void set_nodelay(int fd) {
    int one = 1;
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

inline int tcp_listen_accept(int port) {
    int srv = ::socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) die("socket");
    int one = 1;
    ::setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in a{};
    a.sin_family      = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port        = htons(static_cast<uint16_t>(port));
    if (::bind(srv, reinterpret_cast<sockaddr*>(&a), sizeof(a)) < 0) die("bind");
    if (::listen(srv, 1) < 0) die("listen");

    std::printf("waiting for the sender on TCP :%d ...\n", port);
    std::fflush(stdout);
    int fd = ::accept(srv, nullptr, nullptr);
    if (fd < 0) die("accept");
    ::close(srv);
    set_nodelay(fd);
    return fd;
}

inline int tcp_connect(const char* host, int port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die("socket");

    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port   = htons(static_cast<uint16_t>(port));
    if (::inet_pton(AF_INET, host, &a.sin_addr) != 1) die_msg("bad receiver IP");
    if (::connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) < 0) die("connect");
    set_nodelay(fd);
    return fd;
}

inline void xfer_all(int fd, void* buf, size_t n, bool sending) {
    auto*  p    = static_cast<uint8_t*>(buf);
    size_t done = 0;
    while (done < n) {
        ssize_t k = sending ? ::send(fd, p + done, n - done, 0)
                            : ::recv(fd, p + done, n - done, 0);
        if (k == 0) die_msg("TCP peer closed the side channel early");
        if (k < 0) {
            if (errno == EINTR) continue;
            die(sending ? "send" : "recv");
        }
        done += static_cast<size_t>(k);
    }
}

inline void send_all(int fd, const void* b, size_t n) {
    xfer_all(fd, const_cast<void*>(b), n, true);
}
inline void recv_all(int fd, void* b, size_t n) { xfer_all(fd, b, n, false); }

// Swap WireInfo with the peer.  Both sides send first, then receive; the
// message is tiny and TCP buffers it, so this cannot deadlock.
inline WireInfo exchange(int fd, WireInfo mine) {
    WireInfo theirs{};
    hton_wire(mine);
    send_all(fd, &mine, sizeof(mine));
    recv_all(fd, &theirs, sizeof(theirs));
    ntoh_wire(theirs);
    return theirs;
}

// ─────────────────────────────────────────────────────────────────────────────
// Device and queue pair
// ─────────────────────────────────────────────────────────────────────────────
struct Endpoint {
    ibv_context* ctx  = nullptr;
    ibv_pd*      pd   = nullptr;
    ibv_cq*      cq   = nullptr;
    ibv_qp*      qp   = nullptr;
    uint8_t      port = 1;
    int          gid_index = -1;   // <0 = read it from the GID table
    const char*  peer_ip = nullptr; // used to disambiguate the GID table
    ibv_gid      gid{};
    uint32_t     psn  = 0;
};

inline ibv_context* open_device(const char* want) {
    int          n    = 0;
    ibv_device** list = ibv_get_device_list(&n);
    if (!list || n == 0) die_msg("no RDMA devices (ibv_get_device_list)");

    ibv_device* pick = nullptr;
    if (want && *want) {
        for (int i = 0; i < n; ++i)
            if (std::strcmp(ibv_get_device_name(list[i]), want) == 0) pick = list[i];
        if (!pick) {
            std::fprintf(stderr, "device '%s' not found. Available:\n", want);
            for (int i = 0; i < n; ++i)
                std::fprintf(stderr, "  %s\n", ibv_get_device_name(list[i]));
            std::exit(2);
        }
    } else {
        pick = list[0];
    }
    ibv_context* ctx = ibv_open_device(pick);
    if (!ctx) die("ibv_open_device");
    std::printf("HCA               : %s\n", ibv_get_device_name(pick));
    ibv_free_device_list(list);
    return ctx;
}

inline void gid_to_string(const ibv_gid& g, char* out, size_t n) {
    std::snprintf(out, n,
                  "%02x%02x:%02x%02x:%02x%02x:%02x%02x:"
                  "%02x%02x:%02x%02x:%02x%02x:%02x%02x",
                  g.raw[0], g.raw[1], g.raw[2], g.raw[3], g.raw[4], g.raw[5],
                  g.raw[6], g.raw[7], g.raw[8], g.raw[9], g.raw[10], g.raw[11],
                  g.raw[12], g.raw[13], g.raw[14], g.raw[15]);
}

// Find the GID index for RoCE v2 on the fabric subnet.
//
// The index is a position in a table, not a property of the port, and it moves
// when addresses are added or removed. Two things make a naive search wrong:
//
//   1. Every IPv4 address appears TWICE, once as IB/RoCE v1 and once as
//      RoCE v2, at adjacent indices. Matching on the address alone picks the
//      v1 entry, which will not talk to a v2 peer.
//   2. The PXI carries a link-local 169.254.x address as well as the fabric
//      address, and the link-local one sorts FIRST. Observed table:
//        2 IB/RoCE v1 ::ffff:169.254.71.218
//        3 RoCE v2    ::ffff:169.254.71.218   <- first RoCE v2 IPv4, and wrong
//        4 IB/RoCE v1 ::ffff:192.168.20.2
//        5 RoCE v2    ::ffff:192.168.20.2     <- the one we want
//      So "first RoCE v2 IPv4" silently selects the wrong subnet.
//
// Selecting by peer address removes both hazards: we ask for the local GID that
// can actually reach the peer. peer_ip may be null, in which case link-local is
// skipped and the choice must be unambiguous.
//
// Returns -1 if there is no usable GID, which is itself the answer: the
// interface has no fabric address.
inline int find_roce_v2_ipv4_gid(ibv_context* ctx, uint8_t port,
                                 const char* peer_ip = nullptr) {
    const char* dev = ibv_get_device_name(ctx->device);

    ibv_port_attr pa{};
    if (ibv_query_port(ctx, port, &pa)) die("ibv_query_port");

    uint32_t peer_be = 0;
    if (peer_ip && *peer_ip && ::inet_pton(AF_INET, peer_ip, &peer_be) != 1)
        die_msg("find_roce_v2_ipv4_gid: peer_ip is not a dotted quad");

    int  best = -1, n_candidates = 0;
    char seen[512] = {0};

    for (int i = 0; i < pa.gid_tbl_len; ++i) {
        char path[256];
        std::snprintf(path, sizeof(path),
                      "/sys/class/infiniband/%s/ports/%u/gid_attrs/types/%d",
                      dev, port, i);
        std::FILE* f = std::fopen(path, "r");
        if (!f) continue;               // holes in the table are normal
        char type[64] = {0};
        char* got = std::fgets(type, sizeof(type), f);
        std::fclose(f);
        // Must be RoCE v2 exactly. "IB/RoCE v1" also contains "RoCE v", so
        // anchor at the start of the string.
        if (!got || std::strncmp(type, "RoCE v2", 7) != 0) continue;

        // RoCE v2 covers IPv4 and IPv6. We want the IPv4-mapped form
        // ::ffff:a.b.c.d, so bytes 0-9 zero and bytes 10-11 = 0xff.
        ibv_gid g{};
        if (ibv_query_gid(ctx, port, i, &g)) continue;
        bool v4 = (g.raw[10] == 0xff && g.raw[11] == 0xff);
        for (int b = 0; b < 10 && v4; ++b)
            if (g.raw[b] != 0x00) v4 = false;
        if (!v4) continue;

        // 169.254.0.0/16 is an autoconfigured address, never our fabric.
        if (g.raw[12] == 169 && g.raw[13] == 254) continue;

        uint32_t addr_be = 0;
        std::memcpy(&addr_be, &g.raw[12], 4);

        char line[64];
        std::snprintf(line, sizeof(line), "  index %d = %u.%u.%u.%u\n",
                      i, g.raw[12], g.raw[13], g.raw[14], g.raw[15]);
        std::strncat(seen, line, sizeof(seen) - std::strlen(seen) - 1);

        if (peer_be) {
            // Same /24 as the peer, i.e. the GID that can reach it.
            if ((addr_be & 0x00ffffffu) != (peer_be & 0x00ffffffu)) continue;
            std::printf("GID probe         : index %d = %u.%u.%u.%u "
                        "(RoCE v2, reaches %s)\n",
                        i, g.raw[12], g.raw[13], g.raw[14], g.raw[15], peer_ip);
            return i;
        }
        if (best < 0) best = i;
        ++n_candidates;
    }

    if (best < 0) {
        if (seen[0])
            std::fprintf(stderr, "RoCE v2 IPv4 GIDs present but none on the "
                                 "peer's subnet:\n%s", seen);
        return -1;
    }
    if (n_candidates > 1)
        die_msg("more than one candidate RoCE v2 IPv4 GID and no peer address "
                "to disambiguate. Pass --gid explicitly.");

    ibv_gid g{};
    ibv_query_gid(ctx, port, best, &g);
    std::printf("GID probe         : index %d = %u.%u.%u.%u (RoCE v2)\n",
                best, g.raw[12], g.raw[13], g.raw[14], g.raw[15]);
    return best;
}

// Create a reliable-connection QP and drive it to INIT.
inline void create_qp(Endpoint& ep, int cq_depth, int sq_depth, int rq_depth) {
    ep.pd = ibv_alloc_pd(ep.ctx);
    if (!ep.pd) die("ibv_alloc_pd");

    ep.cq = ibv_create_cq(ep.ctx, cq_depth, nullptr, nullptr, 0);
    if (!ep.cq) die("ibv_create_cq");

    ibv_qp_init_attr ia{};
    ia.send_cq          = ep.cq;
    ia.recv_cq          = ep.cq;
    ia.qp_type          = IBV_QPT_RC;
    ia.sq_sig_all       = 0;
    ia.cap.max_send_wr  = static_cast<uint32_t>(sq_depth);
    ia.cap.max_recv_wr  = static_cast<uint32_t>(rq_depth);
    ia.cap.max_send_sge = 1;
    ia.cap.max_recv_sge = 1;

    ep.qp = ibv_create_qp(ep.pd, &ia);
    if (!ep.qp) die("ibv_create_qp");

    ibv_port_attr pa{};
    if (ibv_query_port(ep.ctx, ep.port, &pa)) die("ibv_query_port");
    if (pa.state != IBV_PORT_ACTIVE)
        die_msg("RDMA port is not ACTIVE. Check the link and the IP config.");

    // gid_index < 0 means "read it", which is the default. An explicit --gid
    // still overrides, but nothing relies on the override being supplied.
    if (ep.gid_index < 0) {
        ep.gid_index = find_roce_v2_ipv4_gid(ep.ctx, ep.port, ep.peer_ip);
        if (ep.gid_index < 0)
            die_msg("no RoCE v2 IPv4 GID on the fabric subnet. The interface "
                    "has no 192.168.20.x address, or the address was lost. "
                    "Re-add it, then retry.");
    }
    if (ibv_query_gid(ep.ctx, ep.port, ep.gid_index, &ep.gid)) die("ibv_query_gid");

    char gs[64];
    gid_to_string(ep.gid, gs, sizeof(gs));
    std::printf("port %u           : ACTIVE, active_mtu=%d, gid[%d]=%s\n",
                ep.port, static_cast<int>(pa.active_mtu), ep.gid_index, gs);

    ibv_qp_attr at{};
    at.qp_state        = IBV_QPS_INIT;
    at.pkey_index      = 0;
    at.port_num        = ep.port;
    at.qp_access_flags = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
                         IBV_ACCESS_REMOTE_READ;
    if (ibv_modify_qp(ep.qp, &at,
                      IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                          IBV_QP_ACCESS_FLAGS))
        die("ibv_modify_qp -> INIT");
}

// INIT -> RTR -> RTS, using the peer's QP number, PSN and GID.
inline void connect_qp(Endpoint& ep, const WireInfo& peer, ibv_mtu mtu) {
    ibv_qp_attr at{};
    at.qp_state              = IBV_QPS_RTR;
    at.path_mtu              = mtu;
    at.dest_qp_num           = peer.qpn;
    at.rq_psn                = peer.psn;
    at.max_dest_rd_atomic    = 1;
    at.min_rnr_timer         = 12;
    at.ah_attr.is_global     = 1;          // RoCEv2: always GRH, never a LID
    at.ah_attr.dlid          = 0;
    at.ah_attr.sl            = 0;
    at.ah_attr.src_path_bits = 0;
    at.ah_attr.port_num      = ep.port;
    std::memcpy(at.ah_attr.grh.dgid.raw, peer.gid, 16);
    at.ah_attr.grh.sgid_index     = static_cast<uint8_t>(ep.gid_index);
    at.ah_attr.grh.hop_limit      = 1;
    at.ah_attr.grh.traffic_class  = 0;
    at.ah_attr.grh.flow_label     = 0;

    if (ibv_modify_qp(ep.qp, &at,
                      IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                          IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                          IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER))
        die("ibv_modify_qp -> RTR");

    ibv_qp_attr rts{};
    rts.qp_state      = IBV_QPS_RTS;
    rts.timeout       = 14;
    rts.retry_cnt     = 7;
    rts.rnr_retry     = 7;
    rts.sq_psn        = ep.psn;
    rts.max_rd_atomic = 1;
    if (ibv_modify_qp(ep.qp, &rts,
                      IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                          IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN |
                          IBV_QP_MAX_QP_RD_ATOMIC))
        die("ibv_modify_qp -> RTS");

    std::printf("queue pair        : RTS (local qpn=%u -> remote qpn=%u)\n",
                ep.qp->qp_num, peer.qpn);
}

inline const char* wc_status(ibv_wc_status s) { return ibv_wc_status_str(s); }

}  // namespace rdma
