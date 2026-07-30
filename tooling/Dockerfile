# Kubernetes agent script-pod tooling image, built from scratch instead
# of extending octopusdeploy/kubernetes-agent-tools-base — avoids pulling
# from a second registry at build time. Only GHCR is used end to end.
#
# Must stay glibc-based (Ubuntu/Debian) — Calamari, the Octopus engine
# that runs inside this container, is a .NET Core self-contained exe and
# doesn't run on musl (Alpine). libicu is the dependency most commonly
# missing; if you see "Couldn't find a valid ICU package installed on
# the system", that's this.
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg apt-transport-https \
        libicu70 \
        ruby-full build-essential libssl-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# kubectl — pinned explicitly. octopusdeploy/kubernetes-agent-tools-base
# auto-selects this per-cluster; doing it ourselves trades that for one
# ARG to bump when AKS's minor version moves.
ARG KUBECTL_VERSION=v1.31.0
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x /usr/local/bin/kubectl

# Azure CLI — Microsoft's install script handles its own apt repo/key.
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# krane, for scripts/deploy.sh
RUN gem install krane --no-document

# No CMD/ENTRYPOINT — Octopus's execution-container model requires none
# be defined, or the step fails.
