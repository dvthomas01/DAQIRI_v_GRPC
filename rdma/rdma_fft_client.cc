// rdma_fft_client.cc — Phase 2 sender.  Runs on the NI PXIe-8881.
//
// No CUDA here.  The PXI has no GPU, which is the whole point: the bytes have
// to cross a real cable and be deposited by a real NIC into memory the CUDA
// driver allocated on the other box.  Everything that made the previous DAQiri
// baseline a same-address loopback is absent by construction.
//
// The receiver drives.  This program does what it is told: read a credit, build
// the signal that credit asks for, RDMA WRITE it with an immediate, wait for the
// send completion, repeat.  It holds no policy of its own so that the timing and
// ordering of the experiment live in exactly one place.
//
// Build on the PXI:
//   g++ -O2 -std=c++20 -I. -o rdma_fft_client \
//       rdma_fft_client.cc signal_gen.cc -libverbs

#include "rdma_contract.h"
#include "rdma_link.h"
#include "signal_gen.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace rdma;

int main(int argc, char** argv) {
    const char* host      = "192.168.20.1";  // the Spark, over RoCE
    const char* dev       = "rocep117s0";
    // -1 means read the RoCE v2 IPv4 GID out of the table. It used to be 5,
    // which was right until the address moved and then it was 3. The index is
    // a position in a list, not a property of the port.
    int         gid_index = -1;
    int         tcp_port  = 18600;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char* {
            if (i + 1 >= argc) die_msg("missing value for an option");
            return argv[++i];
        };
        if (a == "--host")      host = next();
        else if (a == "--dev")  dev = next();
        else if (a == "--gid")  gid_index = std::atoi(next());
        else if (a == "--port") tcp_port = std::atoi(next());
        else {
            std::fprintf(stderr, "unknown option: %s\n", a.c_str());
            return 2;
        }
    }

    std::printf("=== Phase 2 sender (PXI) -> %s ===\n", host);

    Endpoint ep;
    ep.gid_index = gid_index;
    ep.peer_ip   = host;   // pick the local GID that can reach the receiver
    ep.ctx       = open_device(dev);
    ep.psn       = 0x4321;
    create_qp(ep, 32, 16, 16);

    int fd = tcp_connect(host, tcp_port);

    WireInfo mine{};
    mine.qpn        = ep.qp->qp_num;
    mine.psn        = ep.psn;
    mine.rkey       = 0;  // the sender exposes nothing; traffic is one-way
    mine.n_slots    = 0;
    mine.pool_addr  = 0;
    mine.slot_bytes = 0;
    std::memcpy(mine.gid, ep.gid.raw, 16);

    WireInfo peer = exchange(fd, mine);
    connect_qp(ep, peer, IBV_MTU_4096);

    std::printf("receive pool      : %u slots x %llu KB at 0x%llx (rkey 0x%08x)\n",
                peer.n_slots, (unsigned long long)(peer.slot_bytes / 1024),
                (unsigned long long)peer.pool_addr, peer.rkey);

    // One send buffer, sized to the largest slot, registered once.  Same
    // discipline as the receiver: nothing is allocated or registered once the
    // messages start flowing.
    const size_t buf_bytes = peer.slot_bytes;
    void*        raw       = nullptr;
    if (posix_memalign(&raw, 4096, buf_bytes) != 0) die("posix_memalign");
    auto* sbuf = static_cast<float*>(raw);
    std::memset(sbuf, 0, buf_bytes);

    ibv_mr* smr = ibv_reg_mr(ep.pd, sbuf, buf_bytes, IBV_ACCESS_LOCAL_WRITE);
    if (!smr) die("ibv_reg_mr on the send buffer");
    std::printf("send buffer       : %zu KB at %p (lkey 0x%08x)\n\n",
                buf_bytes / 1024, static_cast<void*>(sbuf), smr->lkey);

    SignalConfig cfg;
    cfg.sample_rate_hz = contract::kSampleRateHz;
    cfg.amplitudes     = {1.0f};

    uint64_t sent = 0;
    size_t   last_n = 0;

    for (;;) {
        contract::Credit c{};
        recv_all(fd, &c, sizeof(c));
        if (c.stop) break;

        // Build the tone this sequence number is supposed to carry.  The
        // receiver computes the same frequency from the same shared function
        // and checks the spectrum against it.
        cfg.buffer_size = static_cast<int>(c.n_samples);
        cfg.freqs_hz    = {contract::payload_tone_hz(c.seq)};
        generate_signal(cfg, sbuf, static_cast<int>(c.n_samples));

        const size_t bytes = static_cast<size_t>(c.n_samples) * sizeof(float);

        ibv_sge sge{};
        sge.addr   = reinterpret_cast<uint64_t>(sbuf);
        sge.length = static_cast<uint32_t>(bytes);
        sge.lkey   = smr->lkey;

        ibv_send_wr wr{}, *bad = nullptr;
        wr.wr_id               = c.seq;
        wr.sg_list             = &sge;
        wr.num_sge             = 1;
        wr.opcode              = IBV_WR_RDMA_WRITE_WITH_IMM;
        wr.send_flags          = IBV_SEND_SIGNALED;
        wr.imm_data            = htonl(c.seq);
        wr.wr.rdma.remote_addr = peer.pool_addr + c.remote_off;
        wr.wr.rdma.rkey        = peer.rkey;

        if (ibv_post_send(ep.qp, &wr, &bad)) die("ibv_post_send");

        // Wait for the local completion before taking the next credit, so the
        // send buffer is never rewritten while the NIC is still reading it.
        ibv_wc wc{};
        for (;;) {
            int n = ibv_poll_cq(ep.cq, 1, &wc);
            if (n < 0) die("ibv_poll_cq");
            if (n > 0) break;
        }
        if (wc.status != IBV_WC_SUCCESS) {
            std::fprintf(stderr, "send completion error at seq %u: %s\n", c.seq,
                         wc_status(wc.status));
            return 1;
        }

        ++sent;
        if (c.n_samples != last_n) {
            std::printf("  now sending %zu KB messages\n", bytes / 1024);
            std::fflush(stdout);
            last_n = c.n_samples;
        }
    }

    std::printf("\nsent              : %llu messages\n", (unsigned long long)sent);
    ibv_dereg_mr(smr);
    free(raw);
    ::close(fd);
    std::printf("DONE_SENDER\n");
    return 0;
}
