data botcenters-by-as {
    AS16509     // AWS
    AS14618     // AWS
    AS39682     // GCP
    AS8075      // Azure
    AS15169     // GCP
    AS13335     // Cloudflare
    AS24940     // Hetzner
    AS197207    // MCCI
    AS7979      // Servers.com
    AS14061     // Digital Ocean
    AS16276     // OVH
    AS392934    // Facebook
    AS442244    // Irancell
    AS51167     // CONTABO
    AS27357     // Rackspace
    AS45102     // Alibaba
    AS132203    // Tencent
} 

rule block-botcenter-systems {
    when [CONNECTION::init] {
        deny ip.as memberof(botcenters-by-as)
        permit all
    }
}

policy traffic-ingress-policy {
    099 01 match rule block-reserved-ips sufficient
    099 02 match rule block-reserved-domains sufficient
    100 10 match rule block-botcenter-systems sufficient
    999 01 permit [src.ip.protocol memberof(ip-proto-common-usage)] any sufficient
    999 99 deny all requisite
}
