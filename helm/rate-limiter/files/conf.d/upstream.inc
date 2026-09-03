# Compose backend. The Helm chart renders its own copy of this file pointing
# at the app Service. Resolved at start-up via libc, not the `resolver`
# directive, so nginx exits if "app" does not resolve yet -- hence
# depends_on: app in docker-compose.yml.
upstream app_backend {
    server app:3000;
    keepalive 32;
}
