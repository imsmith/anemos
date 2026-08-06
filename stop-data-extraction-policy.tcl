ye
data ip-proto-common-usage {
    1    // ICMP
    6    // TCP
    17   // UDP
    50   // ESP
    51   // AH
    58   // ICMPv6
    132  // SCTP
    139  // HIP
}

data reserved-ips {
    0.0.0.0/8           // "This" Network
    10.0.0.0/8          // RFC 1918
    100.64.0.0/10       // RFC 6598
    127.0.0.0/8         // Loopback
    169.254.0.0/16      // Link Local
    172.16.0.0/12       // RFC 1918
    192.0.0.0/24        // RFC 6890
    192.0.2.0/24        // TEST-NET-1
    192.88.99.0/24      // 6to4 Relay Anycast
    192.168.0.0/16      // RFC 1918
    198.18.0.0/15       // RFC 2544
    198.51.100.0/24     // TEST-NET-2
    203.0.113.0/24      // TEST-NET-3
    233.252.0.0/24      // MCAST-TEST-NET
    240.0.0.0/4         // Reserved for Future Use
    255.255.255.255/32  // Limited Broadcast
    ::/128              // Unspecified Address
    ::1/128             // Loopback Address
    ::ffff:0:0/96       // IPv4-mapped Address
    64:ff9b::/96        // IPv4-IPv6 Translaton
    64:ff9b:1::/48      // IPv4-IPv6 Translation
    100::/64            // Discard Prefix
    2001::/32           // Teredo
    2001:10::/28        // ORCHID
    2001:20::/28        // ORCHIDv2
    2001:db8::/32       // Documentation
    2002::/16           // 6to4
    3fff::/20           // Documentation
    fc00::/7            // Unique Local Address
    fe80::/10           // Link-Local Unicast
    ff00::/8            // Multicast Address
}
    
data botnet-ips {
    dynamic {
        subscribe webhook https://hooks.example.com/services/ABCDEF1234567890/abcdefghijklmnopqrstuvwxyz
    }
}

data spam-ips {
    dynamic {
        subscribe rss https://example.com/feeds/spam-ip-list.xml
    }
}

data attacker-ips {
    dynamic {
        subscribe amqp amqps://mq.example.com/soc?channel=attacker-ips
    }
}

data gtld-servers {
    dynamic {
        subscribe git git://example.com/repos/gtld-servers.git
        periodic daily
    }
}
data reserved-domains {
    test.
    example.
    invalid.
    localhost.
    home.arpa.
    example.com.
    example.net.
    example.org.
    onion.
    local.
    service.arpa.
    resolver.arpa.
    alt.
    eap-noob.arpa.
    ipv4only.arpa.
    6tisch.arpa.
    10.in-addr.arpa.
    254.169.in-addr.arpa.
    16.172.in-addr.arpa.
    17.172.in-addr.arpa.
    18.172.in-addr.arpa.
    19.172.in-addr.arpa.
    20.172.in-addr.arpa.
    21.172.in-addr.arpa.
    22.172.in-addr.arpa.
    23.172.in-addr.arpa.
    24.172.in-addr.arpa.
    25.172.in-addr.arpa.
    26.172.in-addr.arpa.
    27.172.in-addr.arpa.
    28.172.in-addr.arpa.
    29.172.in-addr.arpa.
    30.172.in-addr.arpa.
    31.172.in-addr.arpa.
    170.0.0.192.in-addr.arpa.
    171.0.0.192.in-addr.arpa.
    168.192.in-addr.arpa.
    8.e.f.ip6.arpa.
    9.e.f.ip6.arpa.
    a.e.f.ip6.arpa.
    b.e.f.ip6.arpa.
}

data historical-tlds {
    su
    yu
    cs
    zr
    bu
    dd
    tp
}

data not-implemented-tlds {
    // Example of not implemented TLDs
}

rule block-reserved-ips {
    when [CONNECTION::init] {
        deny src.ip memberof(reserved-ips)
        deny dst.ip memberof(reserved-ips)
        permit all
    }
}

rule block-reserved-domains {
    when [DNS::request] {
        deny qname memberof(reserved-domains)
        permit all
    }
}

rule block-dns-cc {
    when [DNS::request] {
        deny tld historical-tlds
        deny tld not-implemented-tlds
        deny qtype eq (ANY || AXFR || IXFR)
        permit cctld [geoscheme country-code] memberof(europe, north-america, anz, jkt)
        permit tld eq (com || net || org || edu || gov || arpa)
        forward gtld to gtld-servers
        deny all
    }
}

rule block-ip-geoip {
    when [CONNECTION::init] {
        permit egress (dst.ip [geoscheme geoip] memberof(europe, north-america, anz, jkt))
        deny all
    }
}

rule block-badactor-ips {
    when [CONNECTION::init] {
        deny ip memberof(botnet-ips)
        deny ip memberof(spam-ips)
        deny ip memberof(attacker-ips)
        permit all
    }
}

policy data-egress-policy {
    099 01 match rule block-reserved-ips sufficient
    099 02 match rule block-reserved-domains sufficient
    100 10 match rule block-badactor-ips sufficient
    100 20 match rule block-ip-geoip sufficient
    200 10 match rule block-dns-cc sufficient
    999 01 permit [src.ip.protocol memberof(ip-proto-common-usage)] any sufficient
    999 99 deny all requisite
}