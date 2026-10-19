# Internal PKI (sub-project 10)

A private root CA and one leaf certificate per identity (`identities.txt`). Everything is generated with host OpenSSL
under `pki/out/` (gitignored: never commit it). RSA-2048, leaves 365 days, root 10 years, subject `CN=<id>`, SAN
`DNS:<id>,DNS:localhost,IP:127.0.0.1` (+ extras), EKU serverAuth + clientAuth, keys unencrypted PKCS#8 PEM.

## First setup

    OJ_PUBLIC_HOST=oj.example.org pki/pki.sh init-ca      # once; refuses to overwrite without --force
    OJ_PUBLIC_HOST=oj.example.org pki/pki.sh issue-all    # every id in identities.txt except rogue
    pki/pki.sh status                                     # id, days left, serial

`pki.sh issue <id> [extra-san...]` issues one identity (IPs and DNS names are told apart automatically). `pki.sh rogue`
writes a foreign CA and a `tls-probe` leaf under `out/rogue/` for negative tests. `pki.sh fixtures <dir>` writes the
test-only set (10-year, CN `localhost`, plus gateway/submission/edge/tls-probe and a rogue client) that the Java repos
commit under `src/test/resources/tls/`; those keys are for tests only.

## Distribution

The `tls-init` compose service (alpine, one-shot) runs `install.sh`: it replaces `/tls/<id>` in the `tls` volume with
`pki/out/<id>`, sets the owner from `identities.txt` and modes (dirs 0700, keys 0600, certs 0644). A service mounts its own
subpath read-only at `/etc/oj/tls` and `depends_on: tls-init: service_completed_successfully`. No host sudo is needed.

## Rotation runbook

    pki/pki.sh issue-all                                  # same CA, new leaves
    docker compose up -d --force-recreate tls-init        # replaces the per-id directories in the volume
    docker compose restart                                # Tomcat/Netty reload bundles in place; Kafka, Redis, gRPC and JDBC clients read them at start

Alert `TlsCertificateExpiringSoon` fires 30 days before a chain expires. If a key leaks, `init-ca --force` and re-issue
everything (there are no revocation lists).

## Tests

`bash tests/pki.test.sh` (scripts, install, compose rules) and `bash tests/tls-probe-self.test.sh` (probe helpers against
throwaway servers). `tests/tls.test.sh` is the matrix against the running stack; later tasks add sections.
