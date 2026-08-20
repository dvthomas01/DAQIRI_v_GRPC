// Standalone check that GID selection reads the table rather than assuming an
// index. Argv: <device> <peer-ip>. The printed index must match the RoCE v2
// entry for the local address on the peer's subnet.
//
// This exists because the naive version of this search was wrong twice over:
// every IPv4 appears as both RoCE v1 and v2, and the PXI carries a link-local
// 169.254.x address that sorts ahead of the fabric address.
#include "rdma_link.h"
#include <cstdio>

using namespace rdma;

int main(int argc, char** argv) {
    const char* dev  = (argc > 1) ? argv[1] : "";
    const char* peer = (argc > 2) ? argv[2] : nullptr;

    ibv_context* ctx = open_device(dev);
    int idx = find_roce_v2_ipv4_gid(ctx, 1, peer);
    if (idx < 0) {
        std::printf("RESULT: no RoCE v2 IPv4 GID on the fabric subnet\n");
        return 1;
    }
    ibv_gid g{};
    ibv_query_gid(ctx, 1, idx, &g);
    char gs[64];
    gid_to_string(g, gs, sizeof(gs));
    std::printf("RESULT: gid_index=%d gid=%s\n", idx, gs);
    return 0;
}
