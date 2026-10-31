// SPDX-License-Identifier: MIT
// Air TV Display M1: register _airplay._tcp and _raop._tcp from our own process.
// TXT records are UxPlay 1.74's (docs/discovery-findings.md), with our own deviceid/name/pk/pi.
// Build: cc -o discovery-cli discovery-cli.c   (dns_sd is part of libSystem on macOS)
// Run:   ./discovery-cli <port> [name]        e.g. ./discovery-cli 7100 "Air TV Display M1"
#include <dns_sd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <uuid/uuid.h>

static int en0_mac(unsigned char mac[6]) {
    struct ifaddrs *ifa, *p; int ok = 0;
    if (getifaddrs(&ifa)) return 0;
    for (p = ifa; p; p = p->ifa_next)
        if (p->ifa_addr && p->ifa_addr->sa_family == AF_LINK && !strcmp(p->ifa_name, "en0")) {
            struct sockaddr_dl *d = (struct sockaddr_dl *)p->ifa_addr;
            if (d->sdl_alen == 6) { memcpy(mac, LLADDR(d), 6); ok = 1; }
        }
    freeifaddrs(ifa); return ok;
}

// pk (32 random bytes, hex) and pi (UUID) persisted so they are stable across launches.
static void load_ids(char pk[65], char pi[37]) {
    char path[512]; snprintf(path, sizeof path, "%s/.air-tv-display-m1.ids", getenv("HOME"));
    FILE *f = fopen(path, "r");
    if (f && fscanf(f, "%64s %36s", pk, pi) == 2) { fclose(f); return; }
    if (f) fclose(f);
    unsigned char b[32]; int fd = open("/dev/urandom", O_RDONLY);
    if (read(fd, b, 32) != 32) exit(1);
    close(fd);
    for (int i = 0; i < 32; i++) sprintf(pk + 2 * i, "%02x", b[i]);
    uuid_t u; uuid_generate_random(u); uuid_unparse_lower(u, pi);
    if ((f = fopen(path, "w"))) { fprintf(f, "%s %s\n", pk, pi); fclose(f); }
}

static void put(TXTRecordRef *t, const char *k, const char *v) {
    TXTRecordSetValue(t, k, (uint8_t)strlen(v), v);
}

static void cb(DNSServiceRef s, DNSServiceFlags f, DNSServiceErrorType e, const char *n, const char *r, const char *d, void *c) {
    printf("%s: %s.%s%s err=%d\n", (f & kDNSServiceFlagsAdd) ? "registered" : "removed", n, r, d, (int)e);
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <port> [name]\n", argv[0]); return 2; }
    int port = atoi(argv[1]);
    const char *name = argc > 2 ? argv[2] : "Air TV Display M1";
    unsigned char m[6];
    if (!en0_mac(m)) { fprintf(stderr, "cannot read en0 MAC\n"); return 1; }
    char did[18], did12[13], pk[65], pi[37];
    snprintf(did, sizeof did, "%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
    snprintf(did12, sizeof did12, "%02X%02X%02X%02X%02X%02X", m[0], m[1], m[2], m[3], m[4], m[5]);
    load_ids(pk, pi);

    TXTRecordRef a, r; char buf1[1024], buf2[1024];
    TXTRecordCreate(&a, sizeof buf1, buf1); TXTRecordCreate(&r, sizeof buf2, buf2);
    // _airplay._tcp: same key order as UxPlay
    put(&a, "deviceid", did); put(&a, "features", "0x527FFEE6,0x0"); put(&a, "pw", "false");
    put(&a, "flags", "0x4"); put(&a, "model", "AppleTV3,2"); put(&a, "pk", pk);
    put(&a, "pi", pi); put(&a, "srcvers", "220.68"); put(&a, "vv", "2");
    // _raop._tcp
    put(&r, "ch", "2"); put(&r, "cn", "0,1,2,3"); put(&r, "da", "true"); put(&r, "et", "0,3,5");
    put(&r, "vv", "2"); put(&r, "ft", "0x527FFEE6,0x0"); put(&r, "am", "AppleTV3,2"); put(&r, "md", "0,1,2");
    put(&r, "rhd", "5.6.0.0"); put(&r, "pw", "false"); put(&r, "sf", "0x4"); put(&r, "sr", "44100");
    put(&r, "ss", "16"); put(&r, "sv", "false"); put(&r, "tp", "UDP"); put(&r, "txtvers", "1");
    put(&r, "vs", "220.68"); put(&r, "vn", "65537"); put(&r, "pk", pk);

    char raopname[300]; snprintf(raopname, sizeof raopname, "%s@%s", did12, name);
    DNSServiceRef s1, s2;
    DNSServiceErrorType e1 = DNSServiceRegister(&s1, 0, 0, name, "_airplay._tcp", NULL, NULL, htons(port),
        TXTRecordGetLength(&a), TXTRecordGetBytesPtr(&a), cb, NULL);
    DNSServiceErrorType e2 = DNSServiceRegister(&s2, 0, 0, raopname, "_raop._tcp", NULL, NULL, htons(port),
        TXTRecordGetLength(&r), TXTRecordGetBytesPtr(&r), cb, NULL);
    if (e1 || e2) { fprintf(stderr, "register failed %d %d\n", (int)e1, (int)e2); return 1; }
    printf("deviceid=%s port=%d name=\"%s\" raop=\"%s\"\n", did, port, name, raopname); fflush(stdout);

    int fd1 = DNSServiceRefSockFD(s1), fd2 = DNSServiceRefSockFD(s2);
    for (;;) {
        fd_set fs; FD_ZERO(&fs); FD_SET(fd1, &fs); FD_SET(fd2, &fs);
        if (select((fd1 > fd2 ? fd1 : fd2) + 1, &fs, NULL, NULL, NULL) < 0) break;
        if (FD_ISSET(fd1, &fs)) DNSServiceProcessResult(s1);
        if (FD_ISSET(fd2, &fs)) DNSServiceProcessResult(s2);
    }
    return 0;
}
