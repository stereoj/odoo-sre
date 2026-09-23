Create these two files locally before `docker compose up` — they are gitignored and never committed:

    openssl rand -base64 24 > secrets/db_password.txt
    openssl rand -base64 24 > secrets/admin_password.txt
