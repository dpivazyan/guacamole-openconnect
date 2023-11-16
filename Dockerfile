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
