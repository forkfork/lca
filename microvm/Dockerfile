# Official AL2027 public preview, 2027.0.20260903, pinned after an ECR pull.
ARG BASE_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2027@sha256:a6c4227aac90ecad487ee5fc82849b2d043659fffed35fd68473c262e2a96e94
FROM ${BASE_IMAGE}

# C/CMake build LCA and luv; retain them for coding tasks. No Python/Node runtime.
RUN dnf install -y --setopt=install_weak_deps=False gcc make cmake openssl-devel libxcrypt-devel \
        git-core procps-ng util-linux-core gzip unzip diffutils \
    && dnf swap -y openssl-libs openssl-snapsafe-libs --allowerasing \
    && dnf clean all

WORKDIR /tmp/build
RUN curl -fsSLO https://www.lua.org/ftp/lua-5.5.0.tar.gz \
    && echo '57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d  lua-5.5.0.tar.gz' | sha256sum -c - \
    && tar xzf lua-5.5.0.tar.gz \
    && make -C lua-5.5.0 -j2 linux \
    && make -C lua-5.5.0 install \
    && ln -s /usr/local/bin/lua /usr/local/bin/lua5.5
RUN curl -fsSLO https://luarocks.org/releases/luarocks-3.13.0.tar.gz \
    && echo '245bf6ec560c042cb8948e3d661189292587c5949104677f1eecddc54dbe7e37  luarocks-3.13.0.tar.gz' | sha256sum -c - \
    && tar xzf luarocks-3.13.0.tar.gz \
    && cd luarocks-3.13.0 \
    && ./configure --with-lua=/usr/local --lua-version=5.5 \
    && make -j2 && make install
# The preview repository has no ripgrep package. Lambda's API supports ARM64.
RUN test "$(uname -m)" = aarch64 \
    && curl -fsSL https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz -o rg.tar.gz \
    && echo 'c827481c4ff4ea10c9dc7a4022c8de5db34a5737cb74484d62eb94a95841ab2f  rg.tar.gz' | sha256sum -c - \
    && tar xzf rg.tar.gz \
    && install -m755 ripgrep-14.1.1-aarch64-unknown-linux-gnu/rg /usr/local/bin/rg
RUN luarocks install luasocket 3.1.0-1 \
    && luarocks install luasec 1.3.2-1 \
    && luarocks install lua-cjson 2.1.0.10-1 \
    && luarocks install luv 1.52.1-0

# Only the allowlisted package context is sent to Docker/AWS (package.py).
WORKDIR /opt/lca
COPY lca-dev-1.rockspec ./
COPY c/ c/
COPY lua/ lua/
COPY bin/ bin/
COPY scripts/ scripts/
RUN luarocks make lca-dev-1.rockspec \
    && lua5.5 -e 'require("agent.core"); require("agent.ui"); require("agent.crypto")' \
    && rm -rf /tmp/build
COPY microvm/bootstrap.lua /opt/lca-microvm/bootstrap.lua
COPY microvm/fixture/ /opt/lca-microvm/fixture/
COPY microvm/smoke.sh /opt/lca-microvm/smoke.sh
COPY source-manifest.json /opt/lca-microvm/source-manifest.json
ENV HOME=/root PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin TERM=xterm-256color
RUN mkdir -p /workspace /tmp/lca/logs
WORKDIR /workspace
ENTRYPOINT ["lua5.5", "/opt/lca-microvm/bootstrap.lua"]
