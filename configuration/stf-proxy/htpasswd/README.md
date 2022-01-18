1. Create mcloud.htpasswd file:
```
htpasswd -bc mcloud.htpasswd <user> <password>
```
> replace user and password by your actual values

2. Uncomment in `../nginx.conf` basic auth rules for mcloud
```
auth_basic "Private MCloud Selenium Hub";
auth_basic_user_file /usr/share/nginx/htpasswd/mcloud.htpasswd;
```
