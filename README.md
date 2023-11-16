# Apache Guacamole behind OpenConnect VPN using Docker Compose.

## Why?

This project utilizes Apache Guacamole to establish secure remote connections to resources in a private network. The goal is to facilitate seamless access to internal systems through a clientless remote desktop gateway. By configuring connections, ensuring network accessibility, and implementing authentication, it enables efficient and secure remote access to private network resources.

## Prerequisites or what you need to follow?

You need a virtual machine (Ubuntu in my case) and Docker,Docker Compose plugin installed on it:

 - [Install Docker](https://docs.docker.com/engine/install/ubuntu/)
 - [Install Docker Compose plugin](https://docs.docker.com/compose/install/linux/#install-the-plugin-manually)

Clone the repo:

```shell
git clone "https://github.com/dpivazyan/guacamole-openconnect.git"
cd guacamole-openconnect
```


### First of all we'll start by bulding our own vpn client image

Simply run to have the Docker to build the image 
```shel
docker build -t ovpn .
```
from the Dockerfile 
```shell
# The base image is docker.io/alpine:3.18.4 
# We are installing the openconnect and dnsmasq packages using apk. 
# --no-cache flag means that the package index will not be cached, reducing the size of the final Docker image. (+=24Mb)
# openconnect.sh is the entrypoint for our container
# and a simple healthcheck
FROM docker.io/alpine:3.18.4 
RUN apk add --no-cache openconnect dnsmasq 
WORKDIR /ovpn
COPY ./openconnect.sh .
HEALTHCHECK --start-period=15s --retries=1 \
  CMD pgrep openconnect || exit 1; pgrep dnsmasq || exit 1
ENTRYPOINT ["/ovpn/openconnect.sh"]
```

### Nginx and PostgreSQL
We are going to use Nginx as our reverse proxy and implement SSL/TLS termination using self created certificates
PostgresSQL is authentication backend for Apache Guacamole (MySQL and other can be used)

Run the following script (prepare.sh) to generate SSL certificates and SQL script which can be used to initialize a fresh PostgreSQL database
The nginx.conf is the configuration file for the nginx.

```shell

#!/bin/sh
echo "Preparing folder init and creating ./init/initdb.sql"
mkdir ./init >/dev/null 2>&1
mkdir ./data >/dev/null 2>&1
mkdir ./drive >/dev/null 2>&1
mkdir ./record >/dev/null 2>&1
mkdir -p ./nginx/ssl >/dev/null 2>&1
chmod -R +x ./init
docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --postgresql > ./init/initdb.sql
echo "init db script is generated"
echo "Creating SSL certificates"
openssl req -nodes -newkey rsa:2048 -new -x509 -keyout nginx/ssl/self-ssl.key -out nginx/ssl/self.cert -subj '/C=DE/ST=BY/L=Hintertupfing/O=Dorfwirt/OU=Theke/CN=www.createyour.domain/emailAddress=docker@createyourown.domain'
echo "done"

```

We are using simple nginx configiguration :

```shell
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 5m;
    ssl_prefer_server_ciphers on;
    ssl_stapling on;

    # include /etc/nginx/conf.d/*.conf;

    server {
        listen       443 ssl;
        listen  [::]:443 ssl;
        server_name  localhost;
        ssl_certificate /etc/nginx/ssl/self.cert;
        ssl_certificate_key /etc/nginx/ssl/self-ssl.key;
        ignore_invalid_headers off;

        location / {
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-NginX-Proxy true;
            proxy_cache_bypass $http_upgrade;
            proxy_buffering off;
            proxy_cookie_path / /;

            # This is necessary to pass the correct IP to be hashed
            real_ip_header X-Real-IP;

            proxy_connect_timeout 300;

            # To support websocket
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            #proxy_set_header Connection keep-alive;
            proxy_set_header Connection $http_connection;

            chunked_transfer_encoding off;

            proxy_pass http://localhost:8080; # Apache guacamole tomcat container is litening to 8080 port
        }
    }

}
```


### Change variables in the docker compose and run
```shell
docker compose -f docker-compose.yml up -d
```

```shell
version: '3'
services:
  ovpn:
    image: ovpn
    privileged: true
    ports:
    - 8089:8080
    - 4822:4822
    - 7443:443
    environment:
      VPN_SERVER: 'Your server here'
      USER: "Your user name here"
      PASS: 'Your password'
      #AUTH_GROUP: 'Auth group' 
      #SEARCH_DOMAINS: 'domain1 domain2 domain3'
      #OTP
    cap_add:
      - "NET_ADMIN"
    restart: "unless-stopped"
    volumes:
    - ./openconnect.sh:/ovpn/openconnect.sh
    networks:
      guacnetwork_compose:
  guacd:
    tty: true
    stdin_open: true
    privileged: true
    image: guacamole/guacd
    restart: always
    environment:
      GUACD_LOG_LEVEL: debug
    volumes:
    - ./drive:/drive:rw
    - ./record:/record:rw
    network_mode: "service:ovpn"
  guacamole:
    depends_on:
    - guacd
    privileged: true
    environment:
      LOG_LEVEL: debug
      WEBAPP_CONTEXT: 'ROOT'
      GUACD_HOSTNAME: guacd
      POSTGRES_DATABASE: postgres
      POSTGRES_HOSTNAME: YOUR_HOST_IP_HERE
      POSTGRES_PASSWORD: 'Password123+'
      POSTGRES_USER: postgres
    tty: true
    stdin_open: true
    image: guacamole/guacamole
    restart: always
    network_mode: "service:ovpn"
  postgres:
    container_name: postgres
    image: postgres:15.2-alpine
    environment:
      POSTGRES_USER: postgres
      PGDATA: /var/lib/postgresql/data
      POSTGRES_PASSWORD: Password123+
    command: postgres -c 'max_connections=500'
    volumes:
      - ./data:/var/lib/postgresql/data
      - ./init/initdb.sql:/docker-entrypoint-initdb.d/initdb.sql:z
    ports:
      - "5432:5432"
  nginx:
    container_name: nginx_guacamole_compose
    restart: always
    image: nginx
    volumes:
    - ./nginx.conf:/etc/nginx/nginx.conf:ro
    - ./nginx/ssl/self.cert:/etc/nginx/ssl/self.cert:ro
    - ./nginx/ssl/self-ssl.key:/etc/nginx/ssl/self-ssl.key:ro
    network_mode: "service:ovpn"

networks:
  guacnetwork_compose:
    driver: bridge
```

#### Now you will be able to access guacamole at https://your_host_ip:7443 with default credentials guacadmin:guacadmin
#### Even more use the Apache Guacamole to connect to machines in the private network using SSH,RDP and etc.
