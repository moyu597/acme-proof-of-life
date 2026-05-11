# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/dotnet/sdk:8.0-jammy AS build
WORKDIR /src
COPY AcmeStub.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish AcmeStub.csproj -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0-jammy AS runtime
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_EnableDiagnostics=0
EXPOSE 8080
COPY --from=build /app .

# Recent MS base images ship with a non-root `app` user (uid 1654) already.
# Reuse it if present; otherwise create our own. chown so the app can write
# logs / temp files if needed.
RUN if ! id app >/dev/null 2>&1; then \
      useradd -u 10001 -r app; \
    fi && \
    chown -R app:app /app
USER app

ENTRYPOINT ["dotnet", "AcmeStub.dll"]
