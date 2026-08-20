#!/usr/bin/env bash
# The Spark's grpc-direct differs from the PXI's in two files that the PXI
# audit recorded as untouched: cpp/client_interceptor.cc and the protoc plugin.
# Both are uncommitted local edits on the Spark. Read them.
set -u
cd "$HOME/grpc-direct" || exit 1

echo "###### .cargo/config.toml (Spark-only; can change how the crate builds) ######"
cat .cargo/config.toml 2>/dev/null || echo "  (absent)"

echo
echo "###### diff vs upstream: cpp/client_interceptor.cc ######"
git diff --stat -- cpp/client_interceptor.cc
git diff -- cpp/client_interceptor.cc

echo
echo "###### diff vs upstream: plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go ######"
git diff --stat -- plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go
git diff -- plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go

echo
echo "###### the two interceptor .bak files, sizes and diff chain ######"
ls -l cpp/client_interceptor.cc cpp/client_interceptor.cc.bak cpp/client_interceptor.cc.bak_stream 2>/dev/null
echo "--- bak -> bak_stream ---"
diff cpp/client_interceptor.cc.bak cpp/client_interceptor.cc.bak_stream | head -40
echo "--- bak_stream -> current ---"
diff cpp/client_interceptor.cc.bak_stream cpp/client_interceptor.cc | head -40
