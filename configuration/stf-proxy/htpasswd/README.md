# Basic authentication of the grid

1. Create the `mcloud.htpasswd` file, replace the user and the password by your values:

   ```bash
   htpasswd -bc mcloud.htpasswd <user> <password>
   ```

2. Uncomment the basic authentication rules of the `/mcloud` locations in `../nginx.conf`:

   ```nginx
   auth_basic "Private MCloud Selenium Hub";
   auth_basic_user_file /etc/nginx/htpasswd/mcloud.htpasswd;
   ```

3. Restart the services: `./zebrunner.sh restart`.
