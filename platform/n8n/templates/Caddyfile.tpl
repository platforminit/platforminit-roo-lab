{
    email __TLS_EMAIL__
}

__N8N_DOMAIN__ {
    encode zstd gzip

    header {
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer-when-downgrade
        X-Frame-Options SAMEORIGIN
        -Server
    }

    reverse_proxy n8n:5678
}
