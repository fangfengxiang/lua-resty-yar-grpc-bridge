#!/usr/bin/env bash
# gen.sh — 从 *.proto 生成 Go 代码 + .pb 文件
#
# 位置：t/e2e/proto/gen.sh（与 .proto 同目录）
# 依赖：protoc + protoc-gen-go + protoc-gen-go-grpc
# 安装：go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#       go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
#
# 两个 proto 覆盖 fullServiceName 有/无 package 两种模式：
#   calculator.proto — package calculator（全限定 calculator.Calculator）
#   bare.proto       — 无 package（全限定 Bare）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GO_PROTO_DIR="$SCRIPT_DIR/../go/proto"

mkdir -p "$GO_PROTO_DIR" "$GO_PROTO_DIR/bare"

# ── calculator.proto（有 package）──
echo "[gen] generating Go code from calculator.proto..."
cd "$SCRIPT_DIR"
protoc \
    -I . \
    --go_out="$GO_PROTO_DIR" \
    --go_opt=paths=source_relative \
    --go-grpc_out="$GO_PROTO_DIR" \
    --go-grpc_opt=paths=source_relative \
    calculator.proto

# ── bare.proto（无 package，独立子目录避免 Go package 冲突）──
echo "[gen] generating Go code from bare.proto (no package)..."
protoc \
    -I . \
    --go_out="$GO_PROTO_DIR/bare" \
    --go_opt=paths=source_relative \
    --go-grpc_out="$GO_PROTO_DIR/bare" \
    --go-grpc_opt=paths=source_relative \
    bare.proto

echo "[gen] Go code generated in $GO_PROTO_DIR/"

# ── 生成 .pb 文件（供 OpenResty pb.loadfile 加载）──
echo "[gen] generating .pb files for proxy..."
protoc \
    -I . \
    --descriptor_set_out="$SCRIPT_DIR/calculator.pb" \
    --include_imports \
    calculator.proto
protoc \
    -I . \
    --descriptor_set_out="$SCRIPT_DIR/bare.pb" \
    --include_imports \
    bare.proto

echo "[gen] .pb files generated at $SCRIPT_DIR/"
echo "[gen] done"
