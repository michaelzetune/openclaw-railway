# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.2.9
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080

# Add todoist CLI (sachaos/todoist)
RUN curl -L -o /tmp/todoist.tar.gz \
      https://github.com/sachaos/todoist/releases/download/v0.23.0/todoist_Linux_x86_64.tar.gz && \
    tar xf /tmp/todoist.tar.gz -C /usr/local/bin todoist && \
    chmod +x /usr/local/bin/todoist && \
    rm -f /tmp/todoist.tar.gz

# Add rclone
RUN curl -O https://downloads.rclone.org/rclone-current-linux-amd64.deb && \
    dpkg -i rclone-current-linux-amd64.deb && \
    rm -f rclone-current-linux-amd64.deb

# Add signal-cli native binary
RUN VERSION=$(curl -Ls -o /dev/null -w %{url_effective} \
      https://github.com/AsamK/signal-cli/releases/latest | sed 's/^.*\/v//') && \
    curl -L -O https://github.com/AsamK/signal-cli/releases/download/v"${VERSION}"/signal-cli-"${VERSION}"-Linux-native.tar.gz && \
    tar xf signal-cli-"${VERSION}"-Linux-native.tar.gz && \
    chmod +x signal-cli && \
    mv signal-cli /usr/local/bin/signal-cli && \
    rm -f signal-cli-"${VERSION}"-Linux-native.tar.gz

# Entrypoint: symlink signal-cli data to the persistent volume so account
# registration survives redeploys, then start the wrapper.
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -e' \
  'mkdir -p /data/signal-cli' \
  'mkdir -p /root/.local/share' \
  'ln -sfn /data/signal-cli /root/.local/share/signal-cli' \
  'exec node src/server.js' \
  > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
