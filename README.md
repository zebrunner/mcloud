# Zebrunner MCloud

Zebrunner MCloud is a Device Farm for automated test execution (Appium) and remote web access by humans to physical devices (Android and iOS) including phones, tablets, and TVs. It is fully integrated into the [Zebrunner (Community Edition)](https://zebrunner.github.io/community-edition) ecosystem and can be used both for manual and automated testing.

This repository is the server side of the farm: the docker compose services of [STF](https://github.com/zebrunner/stf) (a fork of [DeviceFarmer/stf](https://github.com/DeviceFarmer/stf) with iOS devices and the Zebrunner sign-in), the Selenium/Appium hub [mcloud-grid](https://github.com/zebrunner/mcloud-grid) and the nginx in front of them, managed by `zebrunner.sh`. The devices are connected by [mcloud-agent](https://github.com/zebrunner/mcloud-agent).

Feel free to support the development with a [**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA) for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## System requirements

| Requirement | Value |
| --- | --- |
| Operating System | Ubuntu 24.04, macOS |
| CPU | 4+ Cores |
| Memory | 16 Gb RAM |
| Free space | SSD 32Gb+ of free space |

- Docker v27+ with the Docker compose plugin
- git 2.20.0+
- openssl with X25519 (OpenSSL 1.1.1+) or Python 3: the setup makes the [CURVE keys](#authentication-of-the-device-hosts) with them (the LibreSSL of macOS has no X25519, Python 3 is used there)

## Run

1. Clone [mcloud](https://github.com/zebrunner/mcloud) and set it up, provide valid protocol, hostname and port:

   ```bash
   git clone https://github.com/zebrunner/mcloud.git && cd mcloud && ./zebrunner.sh setup
   ```

2. Start the services: the setup offers it, otherwise `./zebrunner.sh start`.
3. Open `http://hostname:80/stf` (the protocol, host and port of the setup).
4. Sign in: the default mock sign-in asks the user and the password the setup printed (`STF_AUTH_MOCK_BASIC_AUTH_*` of `variables.env`), then any name and email; the setup also offers OAuth2 and LDAP, see [Sign-in](#sign-in).
5. Go to Settings, Keys and generate a new Access Token.
6. Paste the generated token into `variables.env` as `STF_TOKEN`.
7. Restart the services: `./zebrunner.sh restart`.
8. Set up the servers with Android and iOS devices according to [mcloud-agent](https://github.com/zebrunner/mcloud-agent), the same on Linux and macOS. Set `STF_STORAGE_TOKEN` of mcloud-agent to the `STF_STORAGE_TOKEN` of `variables.env`: the STF storage accepts the uploads of the devices with this token only. Set `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY` and `NODE_REGISTRATION_TOKEN` of mcloud-agent to the ones of `variables.env` and add the public key of every device host to `STF_ZMQ_CURVE_CLIENT_KEYS`, see [Authentication of the device hosts](#authentication-of-the-device-hosts).
9. Use `http://hostname:80/mcloud/grid/console` to see the connected devices and `http://hostname:80/mcloud/wd/hub` as the Selenium/Appium hub URL for test automation.

Follow the installation and configuration guide in [Zebrunner CE](https://zebrunner.github.io/community-edition) to reuse MCloud components effectively for Test Automation.

The commands of `./zebrunner.sh`:

| Command | What it does |
| --- | --- |
| `setup` | writes `.env`, `variables.env` and `configuration/stf-proxy/nginx.conf` from their `*.original` files, then offers to start the services; the values of the previous setup are kept |
| `start` | starts the services and shows their URLs, warns while `STF_TOKEN` is empty; the first start runs `setup` |
| `stop` | stops the services, the containers are kept |
| `restart` | `down` and `start` |
| `down` | stops and removes the containers, the data is kept |
| `shutdown` | removes the containers, the data and the settings |
| `backup`, `restore` | the settings to `*.bak` and the database to `backup/rethinkdb.tar.gz`, and back; `backup` stops the database and the STF units for the copy (the UI and the devices are unavailable meanwhile) and starts them again, a database being written is not copied consistently |
| `version` | the version of MCloud, the tag of the STF image |

## Configuration

`./zebrunner.sh setup` writes the settings from the `*.original` files, `./zebrunner.sh restart` applies their changes. The next setup writes `.env` again and keeps the values of the variables of `variables.env.original` in `variables.env` (but `STF_URL` and the `ZEBRUNNER_*` URLs, which come from the protocol, host and port); the other variables added to `variables.env` are added again after it.

`.env`, the settings of `docker-compose.yml`:

| Variable | Default | Description |
| --- | --- | --- |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud: the protocol, host and port of the setup |
| `STF_PORT` | `8082` | the port of `stf-proxy` on the host |
| `AGENTS_ADDRESS` | `0.0.0.0` | the host address of the ports the device hosts connect to: ZeroMQ of STF and the grid, see [Firewall](#firewall); the value of the previous setup is kept |
| `AGENT_HOSTS` | | the device hosts (`STF_PROVIDER_HOST` of mcloud-agent) separated by commas, see [Screens of the devices](#screens-of-the-devices); the setup asks it, the value of the previous setup is kept |
| `ADB_RELAY` | `false` | `true`: `adb-relay` relays the remote debug ports of the Android devices of STF of `AGENT_HOSTS` (the auto mode), see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay); the value of the previous setup is kept |
| `ADB_RELAY_PORTS` | | the auto mode relays the ports of this range only, `<first>-<last>` (e.g. `7400-7999`): the range opened in the firewall; empty: any port; the value of the previous setup is kept |
| `ADB_RELAY_SYNC_SECONDS` | `30` | the auto mode reads the devices of STF every these seconds; the value of the previous setup is kept |
| `ADB_RELAY_HOSTS` | | the ports `adb-relay` relays in addition (or without the auto mode), `<host>:<port>` separated by commas, e.g. `192.168.30.2:7404,192.168.30.3:7704` (`<host>:<first>-<last>` relays a range, the screens too); the value of the previous setup is kept |
| `LOG_MAX_SIZE`, `LOG_MAX_FILE` | `50m`, `5` | the rotation of the logs of every service (the json-file driver of docker): the size of a file and the number of the files; the values of the previous setup are kept |
| `TAG_NGINX` | `1.31.7` | the tag of `nginx` |
| `TAG_SELENIUM_HUB` | `3.1` | the tag of `public.ecr.aws/zebrunner/mcloud-grid` |
| `TAG_RETHINKDB` | `2.4.3` | the tag of `rethinkdb` |
| `TAG_STF` | `3.1` | the tag of `public.ecr.aws/zebrunner/stf` |
| `AUTH_SYSTEM` | `auth-mock` | the sign-in unit of STF: `auth-mock`, `auth-oauth2` or `auth-ldap` of the [setup](#sign-in), `auth-zebrunner` in [Zebrunner CE](#zebrunner-ce) by default |
| `AUTH_URL` | `auth/mock/` | the path of the sign-in: `auth/mock/`, `auth/oauth/`, `auth/ldap/`, `auth/zebrunner/` |

`variables.env`, the settings of the STF units and of the grid:

| Variable | Default | Description |
| --- | --- | --- |
| `SECRET` | generated | the secret of the sessions and the access tokens of STF; the setup generates it once, a change of it ends the sessions and invalidates the access tokens (`STF_TOKEN` too) |
| `STF_STORAGE_TOKEN` | generated | the token of the STF units for the storage routes, the same value as `STF_STORAGE_TOKEN` of mcloud-agent |
| `STF_TOKEN` | | the access token of the STF user the grid reserves the devices with |
| `NODE_REGISTRATION_TOKEN` | generated | the secret the Appium nodes of the device hosts register in the grid with, the same value as `NODE_REGISTRATION_TOKEN` of mcloud-agent |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud |
| `STF_ROOT_GROUP_NAME` | `MCloud` | the root group of STF |
| `STF_ADMIN_NAME`, `STF_ADMIN_EMAIL` | `admin`, `admin@zebrunner.com` | the administrator of STF, the owner of the root group |
| `ZEBRUNNER_LOGIN_URL`, `ZEBRUNNER_USERINFO_URL` | | the endpoints of Zebrunner IAM for `auth-zebrunner`, set by the setup of Zebrunner CE |
| `STF_AUTH_MOCK_USE_BASIC_AUTH`, `STF_AUTH_MOCK_BASIC_AUTH_USERNAME`, `STF_AUTH_MOCK_BASIC_AUTH_PASSWORD` | `true`, `mcloud`, generated | the shared user and password in front of the mock sign-in |
| `OAUTH_AUTHORIZATION_URL`, `OAUTH_TOKEN_URL`, `OAUTH_USERINFO_URL`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_SCOPE`, `OAUTH_DOMAIN` | | the OAuth2 sign-in, asked by the setup; `OAUTH_CALLBACK_URL` is `<STF_URL>/auth/oauth/callback` |
| `LDAP_URL`, `LDAP_BIND_DN`, `LDAP_BIND_CREDENTIALS`, `LDAP_SEARCH_DN`, `LDAP_SEARCH_FIELD` | | the LDAP sign-in, asked by the setup |
| `RETHINKDB_PORT_28015_TCP` | `tcp://rethinkdb:28015` | the database of STF |
| `RETHINKDB_ENV_AUTHKEY` | generated | the password of the `admin` of RethinkDB the STF units connect with, `stf-migrate` sets it in the database |
| `STF_ZMQ_CURVE_SERVER_SECRET_KEY`, `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY` | generated | the CURVE key pair of the triproxies of STF, the public key goes to mcloud-agent |
| `STF_ZMQ_CURVE_SECRET_KEY` | generated | the CURVE key of the STF units |
| `STF_ZMQ_CURVE_CLIENT_KEYS` | | the public keys of the device hosts (mcloud-agent) separated by commas: the triproxies accept them only |

More settings of STF (e.g. `STF_SESSION_TTL_SECONDS`, the lifetime of a session, or `STF_STORAGE_TEMP_DOWNLOAD_ALLOW`, the private networks the apps may be installed from by URL) are described in [ZEBRUNNER.md of STF](https://github.com/zebrunner/stf/blob/develop/ZEBRUNNER.md#configuration). The settings of the grid (e.g. `NODE_ALLOWED_NETWORKS`, `MAX_NEW_COMMAND_TIMEOUT`, `MCLOUD_LOG_LEVEL`) are described in [mcloud-grid](https://github.com/zebrunner/mcloud-grid#configuration), they go to `environment` of `mcloud-grid` in `docker-compose.yml`.

### Sign-in

The interactive setup asks the sign-in of STF; Zebrunner CE signs in through Zebrunner IAM (`auth-zebrunner`) by default, see [Zebrunner CE](#zebrunner-ce). The values the setup asks are written quoted into `variables.env` (quotes and backslashes are not supported) and are the defaults of the next setup.

| Sign-in | Who is the user | The setup asks |
| --- | --- | --- |
| `mock` (default) | anyone who knows the shared user and password (basic authentication) types a name and an email: whoever knows the name and the email of the admin (`STF_ADMIN_*`) signs in as the admin, so share the password with the trusted users only | nothing, the password is generated and printed |
| `oauth2` | the user of an OpenID Connect / OAuth2 provider (Google, Azure AD, Keycloak, GitLab, ...): an email of `OAUTH_DOMAIN` that the provider does not report as unverified; the admin is the user with the email `STF_ADMIN_EMAIL` | the authorization, token and user info URLs, the client of MCloud at the provider (its redirect URL is `<STF_URL>/auth/oauth/callback`), the scope (`openid email`), the domain |
| `ldap` | the user of the directory with its password | the URL, the bind DN and password (empty for an anonymous search), the search DN and the attribute of the user name (`uid`) |

### https

`./zebrunner.sh setup` with the `https` protocol turns on the ssl of `stf-proxy` with the certificate of the host: put it into `configuration/stf-proxy/ssl/ssl.crt` and its key into `configuration/stf-proxy/ssl/ssl.key` before the setup, which fails without them, for a key of another certificate and for the self-signed pair the repository had (its private key is public). Zebrunner CE gives its own certificate (`nginx/ssl` of Zebrunner CE, its nginx is in front of `stf-proxy`): the setup copies it and warns when it is the self-signed one of the repository of Zebrunner CE. `shutdown` keeps the certificate. `stf-proxy` passes the scheme of the client to STF (`X-Forwarded-Proto`, the one of a proxy in front of it when there is one), so the session cookie is `Secure` behind https. The ssl settings allow TLS 1.2 and 1.3 only.

### Zebrunner CE

[Zebrunner CE](https://zebrunner.github.io/community-edition) runs `./zebrunner.sh setup` of its `mcloud` folder with `ZBR_INSTALLER=1` and its settings: the URL of Zebrunner CE, its nginx is in front of `stf-proxy` (its port `STF_PORT` is `8082`, the port of Zebrunner CE belongs to its nginx), its certificate, the sign-in through Zebrunner IAM. `./zebrunner.sh setup` run in the `mcloud` folder of Zebrunner CE keeps them (from `backup/settings.env` of the last setup of Zebrunner CE) and asks only the admin and the sign-in: `zebrunner` (Zebrunner IAM), `mock`, `oauth2` or `ldap`; the setup of Zebrunner CE keeps that sign-in. Restart the services after it: `./zebrunner.sh restart`.

### Security headers

`stf-proxy` adds `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` and `Content-Security-Policy: frame-ancestors 'self'` to every response and removes `X-Powered-By`: MCloud is not embedded into the pages of other sites. A site that frames MCloud (e.g. another host of Zebrunner) needs `frame-ancestors 'self' https://<host>` instead and no `X-Frame-Options` in `configuration/stf-proxy/nginx.conf`.

### Authentication of the device hosts

The device hosts (mcloud-agent) connect to ZeroMQ of STF (the triproxies), their Appium nodes register in the grid. Neither has an authentication of its own: anyone who reaches their ports reads the events of all the devices or sends commands to them, and a node registered in the grid gets the sessions of its device with their capabilities (the personal `zebrunner:STF_TOKEN` too). So `./zebrunner.sh setup` turns the authentication on:

- the triproxies accept only the clients with a known CURVE key ([ZeroMQ of STF](https://github.com/zebrunner/stf/blob/develop/ZEBRUNNER.md#zeromq)): the STF units and the device hosts of `STF_ZMQ_CURVE_CLIENT_KEYS`, the traffic is encrypted. `./zebrunner.sh setup` makes the keys (X25519, as `stf curve-keygen`) with openssl or, where it has no X25519, with `patch/curve_keygen.py`, the same as of mcloud-agent;
- RethinkDB has a password, `RETHINKDB_ENV_AUTHKEY`, its web console is off and its port is not published: only the STF units of the server use the database;
- the grid registers only the Appium nodes with `NODE_REGISTRATION_TOKEN` of `variables.env`, which the setup generates ([Node registration of mcloud-grid](https://github.com/zebrunner/mcloud-grid#node-registration)), and sends it with its requests to them: the Appium of a device answers the grid only, the devices are used through `/mcloud/wd/hub` and reserved in STF. Set it as `NODE_REGISTRATION_TOKEN` of every mcloud-agent.

A device host makes its own key pair (mcloud-agent prints its public key): add the public key to `STF_ZMQ_CURVE_CLIENT_KEYS` of `variables.env`, separated by commas, and run `./zebrunner.sh restart`. The removal of a key disconnects its device host.

The device hosts need mcloud-agent of the same MCloud release with `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY`, `NODE_REGISTRATION_TOKEN` and `STF_STORAGE_TOKEN`; the others cannot connect.

### Screens of the devices

The screen of a device is a WebSocket of its STF provider on the device host, which the browser opens through `stf-proxy`: `/d/<device host>/<serial>/<port>/`. `stf-proxy` serves it only:

- for a device host of `AGENT_HOSTS` of `.env` (the `STF_PROVIDER_HOST` of every mcloud-agent), any other host gets `403`; without `AGENT_HOSTS` no screen is served;
- on a port 1024-65535;
- for a signed-in user of STF: `stf-proxy` asks `stf-api` about the session cookie (or an access token) of the request, `401` without one.

The setup asks `AGENT_HOSTS` and writes `configuration/stf-proxy/agent-hosts.conf` from it, so does `./zebrunner.sh start`: change `AGENT_HOSTS` of `.env` and run `./zebrunner.sh restart` for a new device host (also in Zebrunner CE).

### Remote debug through the adb relay

STF shows the remote debug of an Android device as `adb connect <host>:<port>`: the host is `STF_PROVIDER_HOST` of mcloud-agent, the port is the remote debug port of the device on its device host, `connect_port` of the device in mcloud-agent or `min_port` + 1 by default (its `min_port` is its screen). A device host in a private network, where only the server of MCloud is public, works through the server (the screens through `stf-proxy`, the tests through the grid, ZeroMQ and the storage are connections of the device host to the server), but the users do not reach the ports of its devices. The optional `adb-relay` relays the remote debug ports through the server.

The auto mode, the recommended setup:

1. Set `ADB_RELAY=true` of `.env` and `ADB_RELAY_PORTS` to the range of the remote debug ports the server relays, the one opened in its firewall (e.g. `ADB_RELAY_PORTS=7400-7999`). The device hosts of the devices are the ones of `AGENT_HOSTS`.
2. Run `./zebrunner.sh restart`: it starts `adb-relay` and warns about an empty `STF_TOKEN` of `variables.env` or `AGENT_HOSTS` and the invalid settings.
3. Set `REMOTE_CONNECT_HOST` of mcloud-agent of these device hosts to the public name of MCloud (the host of `STF_URL`) and deploy it again: STF shows `adb connect <REMOTE_CONNECT_HOST>:<port>` then (mcloud-agent passes it to [mcloud-device](https://github.com/zebrunner/mcloud-device)), `STF_PROVIDER_HOST` without it. `connect_port` of a device in mcloud-agent is optional: it sets the remote debug port, e.g. to keep the ports of the devices in `ADB_RELAY_PORTS`.
4. Open `ADB_RELAY_PORTS` in the firewall of the server for the users, see [Firewall](#firewall), and the remote debug ports of the devices of the device hosts for the server.

`adb-relay` reads the devices of STF from its API every `ADB_RELAY_SYNC_SECONDS` with `STF_TOKEN` of `variables.env` (the access token of the grid: its user sees the devices; read on every sync) and relays the remote debug port of every present Android device whose device host (`/d/<device host>/` of the URL of its screen) is in `AGENT_HOSTS` to the same port of that device host: `connectPort` of the device in STF, the screen port + 1 of an older STF without it (a `connect_port` of mcloud-agent needs the STF of the same MCloud release). It skips a device of another device host, a port out of `ADB_RELAY_PORTS`, a port of MCloud or of `ADB_RELAY_HOSTS` and a port of two devices (both of them); the screen ports are never relayed. A new or a gone device needs nothing: `adb-relay` reloads nginx when the devices change, the open adb sessions go on. It reaches the API through `stf-proxy` on `127.0.0.1:STF_PORT` of the server with the scheme of `STF_URL` (`stf-proxy` has the certificate of the public name, it is not checked on the loopback address); when the API fails, the relay keeps its devices. `docker logs adb-relay` lists the relayed devices and the skipped ones with the reason whenever they change.

A fixed list instead of the auto mode, or in addition to it: `ADB_RELAY_HOSTS` of `.env`, the remote debug ports of the devices, `<host>:<port>` separated by commas, e.g. `ADB_RELAY_HOSTS=192.168.30.2:7404,192.168.30.2:7464,192.168.30.3:7704`; `./zebrunner.sh doctor` of mcloud-agent prints the entries of its host. The host is an IPv4 address or a host name of the device host in the network of the server, a host is in an entry for every device; the ports are 1024-65535, unique (the server relays a port to one device host) and not the ones of MCloud (`STF_PORT`, `4446`, `7160`, `7250`, `7260`, `7270`). `./zebrunner.sh restart` writes `configuration/adb-relay/relay-hosts.conf` from it (an invalid entry, a port of an earlier entry or of MCloud is reported and skipped) and starts `adb-relay`; `REMOTE_CONNECT_HOST` and the firewall as in the auto mode.

`adb-relay` is the nginx of `stf-proxy` (`TAG_NGINX`) in the network of the host (`network_mode: host`: a port per device, not published one by one) with `configuration/adb-relay/adb-relay.sh`, the sync of the auto mode: it listens on every relayed port on every address of the server and connects to the same port of the device host; an idle session ends after 24 hours. `./zebrunner.sh` starts it (the compose profile `adb-relay`) only when `ADB_RELAY=true` or `ADB_RELAY_HOSTS` has a valid entry, `stop`, `down`, `restart` and `shutdown` take it along also after they are cleared: run `./zebrunner.sh restart` after a change of the `ADB_RELAY*` settings (also in Zebrunner CE). `docker logs adb-relay` also shows every session: the client, the port, the device host, the bytes and the duration. On macOS the network of the host of Docker Desktop is the one of its VM: the ports need its host networking (Settings, Resources, Network).

The relay has no authentication of its own, it makes its ports public as they are. The remote debug port of a device listens only while a user of STF uses the device (the Remote debug of its dashboard starts it) and accepts an adb client with an adb key of that user only (STF, Settings, ADB keys): an unknown key makes STF ask that user to add it, add only your own keys.

An entry `<host>:<first>-<last>` of `ADB_RELAY_HOSTS` relays a whole range, e.g. `min_port`-`max_port` of all the devices of a device host. It is accepted, but `./zebrunner.sh` warns: the range also makes the screens of the devices public (their `min_port`), WebSockets without an authentication of their own that `stf-proxy` serves to the signed-in users only (see [Screens of the devices](#screens-of-the-devices)), the relay to anyone. Use a range only behind a firewall that opens it to the networks of the users (the office, a VPN); the auto mode relays no screen.

### Firewall

The ports of the host and who needs them; close the others:

| Port | Service | Clients |
| --- | --- | --- |
| `STF_PORT` | `stf-proxy` | the users, the tests, the device hosts (the storage, the screens) |
| `7160`, `7250`, `7260`, `7270` (`AGENTS_ADDRESS`) | ZeroMQ of STF (`stf-triproxy-app`, `stf-triproxy-dev`) | the device hosts |
| `4446` (`AGENTS_ADDRESS`) | `mcloud-grid` | the device hosts (Appium registers to the grid); the tests use `/mcloud/wd/hub` of `STF_PORT` |
| `ADB_RELAY_PORTS`, the ports of `ADB_RELAY_HOSTS` | `adb-relay` (optional) | the users: `adb connect` of the remote debug of the devices of the device hosts in a private network, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay) |

`AGENTS_ADDRESS` publishes these ports on one address of the host, e.g. the one of the network of the device hosts. A device host publishes the ports of its devices for the server (`stf-proxy` serves the screens to the users) and for the remote ADB of the users, see [mcloud-agent](https://github.com/zebrunner/mcloud-agent); `adb-relay` relays them to the users from a device host in a private network.

### Basic authentication of the grid

See [configuration/stf-proxy/htpasswd](configuration/stf-proxy/htpasswd/README.md).

### Files and secrets

`variables.env`, `backup/settings.env`, the key of the certificate (`configuration/stf-proxy/ssl/ssl.key`), the archive of the database (`backup/rethinkdb.tar.gz`) and their backups hold the secrets of the deployment: `setup`, `start`, `backup` and `restore` keep them readable for their owner only (`600`). Run `zebrunner.sh` as the user of the deployment; a `sudo ./zebrunner.sh` gives the files it writes back to the owner of the folder.

## Services

All the services but `adb-relay` (the network of the host) are in the external docker network `infra`, which `./zebrunner.sh start` creates.

| Service | Image | What it does |
| --- | --- | --- |
| `stf-proxy` | `nginx` | the entry point on `STF_PORT`: STF, the grid under `/mcloud`, the static files of the grid console |
| `mcloud-grid` | `public.ecr.aws/zebrunner/mcloud-grid` | the Selenium/Appium hub of the devices, also on the port `4446` of the host (`AGENTS_ADDRESS`) |
| `rethinkdb` | `rethinkdb` | the database of STF, the volume `stf-db-volume`, with the password `RETHINKDB_ENV_AUTHKEY` and without its web console, not published on the host |
| `stf-migrate` | `public.ecr.aws/zebrunner/stf` | creates and updates the tables of the database, the other STF units start after it |
| `stf-app`, `stf-auth`, `stf-api`, `stf-websocket` | `public.ecr.aws/zebrunner/stf` | the UI, the sign-in, the REST API and the websocket of STF |
| `stf-processor001`, `stf-reaper`, `stf-api-groups-engine` | `public.ecr.aws/zebrunner/stf` | the device events, the heartbeats and the groups of STF |
| `stf-triproxy-app`, `stf-triproxy-dev` | `public.ecr.aws/zebrunner/stf` | the message brokers of the STF units and of the devices, the ports `7160` and `7250`-`7270` of the host (`AGENTS_ADDRESS`) |
| `stf-storage-temp`, `stf-storage-plugin-apk`, `stf-storage-plugin-image` | `public.ecr.aws/zebrunner/stf` | the storage of the apps and screenshots, the volume `stf-temp-volume`; protected by `STF_STORAGE_TOKEN` |
| `adb-relay` | `nginx` | optional, with `ADB_RELAY=true` or `ADB_RELAY_HOSTS` only: the TCP relay of the remote debug ports of the devices of the device hosts in a private network, in the network of the host, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay) |

Every service has a healthcheck (`docker ps` shows `unhealthy` for one that stopped answering): the STF units with an HTTP port and the triproxies (a TCP connection), `stf-proxy`, `rethinkdb`, `adb-relay` (nginx listens on its ports), `mcloud-grid` (the one of its image), and the units without a port, `stf-processor001`, `stf-reaper` and `stf-api-groups-engine`: they are healthy while they are connected to their ZeroMQ brokers and to RethinkDB (`stf-migrate` runs once); `stf-proxy` starts once `stf-app` is healthy. Docker restarts a service when it exits, not when it is unhealthy. The logs of every service are rotated (`LOG_MAX_SIZE`, `LOG_MAX_FILE`).

## Endpoints

| Endpoint | Content |
| --- | --- |
| `/stf` | the UI of STF |
| `/api/v1/` | the REST API of STF, with an access token |
| `/mcloud/wd/hub` | the Selenium/Appium hub URL |
| `/mcloud/grid/console` | the grid console with the devices |
| `/mcloud/grid/admin/DevicesServlet` | the devices of the grid as JSON: their status and sessions |
| `/mcloud/grid/admin/AllSessionsServlet` | the active sessions as JSON |
| `/mcloud/grid/admin/MetricsServlet` | the Prometheus metrics of the grid |
| `POST /mcloud/grid/admin/TerminateSessionServlet` | terminates the session of a device, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#terminating-a-session) |

## Upgrade

An MCloud release works with mcloud-agent of the same release only (the images of the device hosts, the authentication of the device hosts): update the server and all the device hosts together.

1. Update the repository: `git pull`.
2. Run `./zebrunner.sh setup`: it keeps the settings of the previous setup and generates the missing ones, check the settings of mcloud-agent it prints.
3. Update mcloud-agent of every device host to the same release, see its README.
4. Restart the services: `./zebrunner.sh restart`; `stf-migrate` updates the tables of the database.

## Troubleshooting

`docker logs <service>` shows the log of a service, `docker ps` the unhealthy ones (see [Services](#services)).

| Symptom | Cause and fix |
| --- | --- |
| `./zebrunner.sh start` fails to pull: `denied: Your authorization token has expired` or `403 Forbidden` from `public.ecr.aws` | an expired login to public.ecr.aws in `~/.docker/config.json` of the user: the images are public, `docker logout public.ecr.aws` (or log in again: `aws ecr-public get-login-password --region us-east-1 \| docker login --username AWS --password-stdin public.ecr.aws`) |
| the pull fails with `manifest unknown` | the tag of `TAG_*` of `.env` is not published: the tags of `.env.original` of the current MCloud |
| the devices are in STF, not in `/mcloud/grid/console`; `mcloud-grid` logs `Could not get the device '<udid>' from STF (HTTP 401), the node is not registered.` | `STF_TOKEN` of `variables.env` is empty or not an access token of STF: generate one (STF, Settings, Keys), set it and `./zebrunner.sh restart` (`start` warns while it is empty) |
| `mcloud-grid` logs `Node <url> has no or another NODE_REGISTRATION_TOKEN than the hub, so it is not registered.` | `NODE_REGISTRATION_TOKEN` of the device host differs from `variables.env`: set the one of `variables.env` in mcloud-agent and run its `./zebrunner.sh ansible`, `zebrunner-farm restart` |
| `mcloud-grid` logs `Node <url> is not reachable from the hub` | the hub does not reach the Appium port of the device host: `STF_PROVIDER_HOST` of mcloud-agent and the firewall of the device host |
| the device host is up, its devices are not in STF (the `stf` container of an Android device restarts after `Providing all 0 of 1 device(s)`); `stf-triproxy-app` or `stf-triproxy-dev` logs `Refused the ZeroMQ client <address> with the unknown key "<key>"` | the public key of the device host is not in `STF_ZMQ_CURVE_CLIENT_KEYS` of the running services: add the one `./zebrunner.sh curve-key` of mcloud-agent prints to `variables.env` and `./zebrunner.sh restart` (a change of `variables.env` needs it), then `zebrunner-farm restart` on the device host for its iOS devices; a device host with another `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY` than `variables.env` is not let in either, see [Authentication of the device hosts](#authentication-of-the-device-hosts) |
| the screen of a device stays gray, `/d/<device host>/...` answers `403` | the device host is not in `AGENT_HOSTS` of `.env`: add it and `./zebrunner.sh restart`, see [Screens of the devices](#screens-of-the-devices) (`401`: the user is not signed in) |
| the screenshots or the app installs of the devices fail with `401` / `403` | `STF_STORAGE_TOKEN` of the device host differs from `variables.env` |
| `configuration/stf-proxy/agent-hosts.conf is not writable` (`Permission denied`) | the file was written by root (`sudo ./zebrunner.sh ...`): `rm -f configuration/stf-proxy/agent-hosts.conf` and `./zebrunner.sh restart`; run `zebrunner.sh` as the user of the deployment |
| `configuration/adb-relay/relay-hosts.conf is not writable` | the file was written by root (`sudo ./zebrunner.sh ...`): `rm -f configuration/adb-relay/relay-hosts.conf` and `./zebrunner.sh restart`; `adb-relay` keeps the servers it has until then |
| `adb connect` of STF to a device of a device host in a private network times out or fails | `REMOTE_CONNECT_HOST` of mcloud-agent is not the public name of MCloud, the relay skips the port or the firewall of the server closes it, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay): `docker logs adb-relay` lists the relayed devices and the skipped ones with the reason (e.g. a device host out of `AGENT_HOSTS`, a port out of `ADB_RELAY_PORTS`), the ports of `ADB_RELAY_HOSTS` are in `configuration/adb-relay/relay-hosts.conf`; it also shows the sessions and why a device host refused one |
| `docker logs adb-relay` shows `The STF API ... failed` or `answered without devices` | the auto mode does not read the devices: `401` is an invalid `STF_TOKEN` of `variables.env` (a new access token of STF, Settings, Keys); a failed connection is `stf-proxy` not running or not with the scheme of `STF_URL` (http or https); the relay keeps its devices until the next successful sync |
| `adb-relay` restarts, `docker logs adb-relay` shows `bind() to 0.0.0.0:<port> failed (98: Address already in use)` | another program of the server listens on a relayed port: move the ports of the device in mcloud-agent (`connect_port`, `min_port`) and its entry of `ADB_RELAY_HOSTS`, or keep the port out of `ADB_RELAY_PORTS` |
| `The certificate of Zebrunner CE (../nginx/ssl/ssl.crt and ssl.key) cannot be copied` | the key of Zebrunner CE is readable for root only (e.g. written by certbot): make it readable for the user of the setup (its group and `chmod 640`) instead of `sudo ./zebrunner.sh setup` |
| a device of a gone device host is not removed by Settings, Devices of STF (nothing happens) | the removing filters of the page skip the devices that are controlled, booked or annotated, and a device whose host went away during a session stays controlled: set *Controlled* (and the others) of the filters to *Any* |
| macOS (Docker Desktop): `./zebrunner.sh start` hangs, `stf-proxy` stays `Created`, `docker inspect stf-proxy` does not answer | the port forwarding of Docker Desktop hangs (seen after a failed start): `docker desktop restart` (or quit and start Docker Desktop), then `./zebrunner.sh start` |
| `stf-processor001`, `stf-reaper` or `stf-api-groups-engine` is `unhealthy` | the unit lost its ZeroMQ brokers (`stf-triproxy-*`) or RethinkDB, docker does not restart an unhealthy unit: see the state and the logs of the brokers and of `rethinkdb`, then `./zebrunner.sh restart` |

## Components

- [mcloud-agent](https://github.com/zebrunner/mcloud-agent) - Device Farm agent for connecting Android and iOS devices including phones, tablets, and TVs over USB or Wi-Fi, Android emulators and iOS / tvOS simulators (macOS) via Linux or macOS.
- [mcloud-device](https://github.com/zebrunner/mcloud-device) - Dockerized STF provider image for Android and iOS devices.
- [mcloud-grid](https://github.com/zebrunner/mcloud-grid) - Enhanced Selenium Grid for automating physical devices and emulators/simulators via Appium.
- [stf](https://github.com/zebrunner/stf) - the STF of MCloud with iOS devices and the Zebrunner sign-in.
- [appium](https://github.com/zebrunner/appium) - Enhanced Appium image with low-level video recording and local storage for ipa/apk artifacts.

## Development

| Target | What it checks | Needs |
| --- | --- | --- |
| `make check` | everything below, as CI runs it | |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, pymarkdown, shellcheck, shfmt, ruff, the text files, `docker compose config` with the `*.original` settings, also with the profile `adb-relay` | Python 3; on macOS `brew install hadolint` |
| `make test` | `tests/zebrunner_test.sh` and `tests/utility_test.sh`: the commands of `zebrunner.sh` on a copy of the repository with a `docker` stub; `tests/adb_relay_test.sh`: the sync of `configuration/adb-relay/adb-relay.sh` with answers of the STF API and stubs | bash |
| `make docker` | `tests/compose_test.sh`: the setup, the start and the endpoints of the services, `adb-relay` with a stand-in device host, then their shutdown; `tests/adb_relay_docker_test.sh`: the auto mode of `adb-relay` with a fake STF API and a stand-in device host (the sessions, the reload, the errors); `TAG_STF=<tag> TAG_SELENIUM_HUB=<tag> make docker` checks other images | Docker, no other MCloud on the machine |

The tests write JUnit XML into `$JUNIT_DIR` when it is set. CI (`.github/workflows/ci.yml`) runs the jobs `lint`, `tests` (Linux and macOS) and `docker` on the pushes and pull requests.

The end-to-end test of the farm (`.github/workflows/e2e.yml`, on the pushes and pull requests, every night and on demand) runs on a GitHub runner with KVM:

1. `tests/e2e/build-images.sh` builds the images of the farm with an Android device from the `develop` branches of their repositories with the tags of `.env.original` and of `mcloud-agent`; only the uploader is pulled from `public.ecr.aws/zebrunner` (`artifacts-uploader` is private). The inputs `ref` (all the repositories) and `refs` (single ones: `STF_REF=fix/x MCLOUD_AGENT_REF=feat/y`) of a manual run take other branches, as `E2E_REF` and `E2E_REFS` or `<REPOSITORY>_REF` of the script.
2. `tests/e2e/emulator.sh` starts with an Android emulator (`android-emulator-runner`) and relays its adb to the containers.
3. `tests/e2e/farm_test.sh` sets up and starts MCloud of this checkout, MinIO for the artifacts and a device host of `mcloud-agent` with the emulator, then checks the containers, the device in STF and in the grid, an Appium session with an app, the screen of the device in STF, the upload of a file to STF and the artifacts of the session (the video too) in S3.

The logs of every container and of the emulator are the artifact `e2e` of the run (with JUnit XML). `tests/e2e/farm_test.sh` changes the machine (the ports, udev, `zebrunner-farm`), run it only on disposable machines.

The conventions of the style, the formatting and the tooling of this repository are in [CONVENTIONS.md](CONVENTIONS.md), the same in all the MCloud repositories. The rules of this repository:

- `docker-compose.yml` takes the image tags (`TAG_*`) and the ports from `.env`, the settings of the services from `variables.env`; `./zebrunner.sh setup` writes both from `.env.original` and `variables.env.original`, which keep the defaults. `make lint` checks `docker compose config` with the `*.original` files.
- Every image is pinned by its `TAG_*` in `.env.original`, the table of `.env` shows the same default (both checked by `make lint`).
- `zebrunner.sh` and `patch/*.sh` are [host scripts](CONVENTIONS.md#host-scripts): the interface of Zebrunner CE (`ZBR_INSTALLER`, the `ZBR_*` settings, `SHUTDOWN_CONFIRMED`, `.disabled`) and the commands stay compatible.
- The static files of the Selenium grid console (`configuration/stf-proxy/grid/`) are kept byte for byte: `generated` of `tests/lint_project.sh` and unset formatting in `.editorconfig`.
- A test of the services goes to `tests/compose_test.sh` (`DOCKER_TESTS`), a test of the commands of `zebrunner.sh` without docker to `tests/zebrunner_test.sh`.
- `configuration/adb-relay/adb-relay.sh` runs in the nginx image (bash 5, mawk) and `make test` runs its functions on macOS too (bash 3.2, BSD awk): it stays compatible with both, `tests/adb_relay_docker_test.sh` runs its tests in the image.

## Support

- [Zebrunner PRO](https://zebrunner.com)
- [Zebrunner CE](https://zebrunner.github.io/community-edition)
- [Zebrunner Reporting](https://zebrunner.com/documentation)
- [Carina Guide](http://zebrunner.github.io/carina)
- [Demo Project](https://github.com/zebrunner/carina-demo)
- [Telegram Channel](https://t.me/zebrunner)

## License

[Apache License 2.0](LICENSE)
