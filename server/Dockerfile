# build enclave_base from https://github.com/aws/aws-nitro-enclaves-sdk-c/blob/main/containers/Dockerfile.al2
ARG BASE_IMAGE=enclave_base

FROM $BASE_IMAGE

WORKDIR /app
COPY run.sh ./

ENV AWS_STS_REGIONAL_ENDPOINTS=regional
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/app:/usr/local/lib
ENV HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1

# Install build and runtime dependencies for llama.cpp
RUN dnf install -y git make gcc gcc-c++ cmake libgomp libstdc++ && \
    dnf clean all

# Clone and build llama.cpp directly in the final image
RUN git clone https://github.com/ggerganov/llama.cpp.git /tmp/llama.cpp && \
    cd /tmp/llama.cpp && \
    mkdir build && \
    cd build && \
    cmake .. \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_CURL=OFF \
        -DGGML_CUDA=OFF \
        -DGGML_METAL=OFF \
        -DGGML_OPENCL=OFF \
        -DGGML_VULKAN=OFF && \
    cmake --build . --config Release -j $(nproc) && \
    cp bin/llama-server /usr/local/bin/ && \
    cp bin/llama-cli /usr/local/bin/ && \
    cp bin/libmtmd.so /usr/local/lib/ && \
    cp bin/libggml*.so /usr/local/lib/ && \
    cp bin/libllama.so /usr/local/lib/ && \
    ldconfig && \
    cd / && \
    rm -rf /tmp/llama.cpp && \
    dnf clean all

RUN chmod +x /usr/local/bin/llama-server /usr/local/bin/llama-cli /app/run.sh
CMD ["/app/run.sh"]
