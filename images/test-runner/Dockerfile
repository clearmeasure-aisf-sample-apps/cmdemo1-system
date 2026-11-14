# Octopus acceptance-test worker: Playwright (Chromium + pwsh) and the .NET 10 SDK.
# Match Microsoft.Playwright.NUnit 1.61.0 in cmdemo1-workorders (Chromium 1228). Published to GHCR by
# job publish-test-runner of .github/workflows/system.yml; octopus/main.tf points the Acceptance tests
# steps at that image (issue #648).
FROM mcr.microsoft.com/playwright/dotnet:v1.61.0-noble

USER root
# The noble tag may already include SDK 10; install only when missing so deploys never need
# dotnet-install.sh. Same install-dir as the Microsoft .NET images (/usr/share/dotnet).
RUN set -euo pipefail; \
    if ! dotnet --list-sdks | grep -qE '^10\.'; then \
      curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; \
      bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet --no-path; \
      rm -f /tmp/dotnet-install.sh; \
    fi; \
    dotnet --list-sdks | grep -E '^10\.'

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_NOLOGO=1
