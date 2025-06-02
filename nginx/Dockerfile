# Dockerfile (nginx)
# Build this file alongside Thymoe.html
FROM nginx:1.24-alpine

# Remove default server block
RUN rm /etc/nginx/conf.d/default.conf

# Add custom server block
RUN mkdir -p /etc/nginx/conf.d && \
    cat << 'EOF' > /etc/nginx/conf.d/default.conf
server {
    listen       80 default_server;
    listen  [::]:80 default_server;
    server_name  _;

    root   /usr/share/nginx/html;
    index  Thymoe.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

# Copy Thymoe.html into place
COPY Thymoe.html /usr/share/nginx/html/Thymoe.html

# Expose port and run
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
