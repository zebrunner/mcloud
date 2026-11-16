# Basic authentication of the grid

1. Create the `mcloud.htpasswd` file in this folder, replace the user by your value (`htpasswd` asks the password):

   ```bash
   htpasswd -c mcloud.htpasswd <user>
   ```

2. Restart the services: `./zebrunner.sh restart`.

While `mcloud.htpasswd` exists, `./zebrunner.sh setup` and `start` turn on the basic authentication of the `/mcloud` locations of `../nginx.conf` (the hub, the console and the Playwright sessions); without it they turn it off.
