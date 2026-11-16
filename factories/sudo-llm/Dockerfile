# llama.cpp server, CUDA 12.6 (matches compooper driver 561.00 / CUDA 12.6).
# The official ghcr.io/ggml-org/llama.cpp:server-cuda image is built with CUDA
# 12.8, which needs driver >= 570.26 — too new for the RTX 4070's 561.00 driver.
# So we build llama-server from source against CUDA 12.6, targeting sm_89
# (Ada Lovelace = RTX 4070), and run it in the CUDA 12.6 runtime image.

FROM nvidia/cuda:12.6.0-devel-ubuntu22.04 AS build
RUN apt-get update && \
    apt-get install -y --no-install-recommends git build-essential cmake && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git .
RUN cmake -B build \
      -DGGML_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES=89 \
      -DGGML_NATIVE=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=ON
RUN cmake --build build --config Release -j"$(nproc)" --target llama-server

FROM nvidia/cuda:12.6.0-runtime-ubuntu22.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgomp1 curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/bin/llama-server /app/llama-server
WORKDIR /app
ENV LLAMA_ARG_HOST=0.0.0.0 LLAMA_ARG_PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/llama-server"]
