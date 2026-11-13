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
- openssl with X25519 (OpenSSL 1.1.1+) or Python 3: the setup makes the [CURVE keys](#authentication-of-the-nodes) of the server with them (the LibreSSL of macOS has no X25519, Python 3 is used there); `./zebrunner.sh node-invite` makes the pin of the certificate with openssl (LibreSSL too) or Python 3
- curl: the [node commands](#commands-of-the-nodes) call the STF API with it
- a certificate of the host for https (`configuration/stf-proxy/ssl`, see [https](#https)): the nodes are enrolled over https only

## Run

The server:

1. Clone [mcloud](https://github.com/zebrunner/mcloud), put the certificate of the host into `configuration/stf-proxy/ssl/ssl.crt` and its key into `configuration/stf-proxy/ssl/ssl.key` ([https](#https)) and set it up with the protocol `https`, the host name and the port:

   ```bash
   git clone https://github.com/zebrunner/mcloud.git && cd mcloud && ./zebrunner.sh setup
   ```

2. Set `AGENTS_ADDRESS` of `.env` to the address of the server the nodes reach (its LAN address for the nodes in its network or on the server itself, see [Nodes in a private network](#nodes-in-a-private-network) and [Devices on the MCloud server](#devices-on-the-mcloud-server)); `0.0.0.0`, the default, lets the nodes use the public name of `STF_URL`.
3. Start the services: the setup offers it, otherwise `./zebrunner.sh start`.
4. Open `https://<host>:<port>/stf` and sign in: the default mock sign-in asks the user and the password the setup printed (`STF_AUTH_MOCK_BASIC_AUTH_*` of `variables.env`), then the name and the email of the admin (`STF_ADMIN_*`); the setup also offers OAuth2 and LDAP, see [Sign-in](#sign-in).
5. Go to Settings, Keys, generate an access token of the admin and set it as `STF_TOKEN` of `variables.env`: the grid reserves the devices with it, the [node commands](#commands-of-the-nodes) and `adb-relay` read the registry of the nodes with it.
6. Restart the services: `./zebrunner.sh restart`.

Every node (a Linux or macOS host with Android and iOS devices, [mcloud-agent](https://github.com/zebrunner/mcloud-agent)):

1. On the server: `./zebrunner.sh node-invite <label> <address>` prints the join string of the node once, see [Enrollment](#enrollment).
2. On the node: `./zebrunner.sh setup` of mcloud-agent, then `./zebrunner.sh join` with the join string, the devices of the node in its settings, `./zebrunner.sh ansible` and `zebrunner-farm start`, as mcloud-agent describes; `./zebrunner.sh doctor` of mcloud-agent checks the node.
3. On the server: `./zebrunner.sh nodes check <label>` shows the node, its devices in STF and whether the server reaches their screens, see [Diagnostics](#diagnostics).

Use `https://<host>:<port>/mcloud/grid/console` to see the devices of the grid and `https://<host>:<port>/mcloud/wd/hub` as the Selenium/Appium hub URL for test automation. Follow the installation and configuration guide in [Zebrunner CE](https://zebrunner.github.io/community-edition) to reuse MCloud components effectively for Test Automation.

The commands of `./zebrunner.sh`:

| Command | What it does |
| --- | --- |
| `setup` | writes `.env`, `variables.env` and `configuration/stf-proxy/nginx.conf` from their `*.original` files, then offers to start the services; the values of the previous setup are kept |
| `start` | starts the services and shows their URLs, warns while `STF_TOKEN` is empty and while `AGENTS_ADDRESS` is `0.0.0.0`; the first start runs `setup` |
| `stop` | stops the services, the containers are kept |
| `restart` | `down` and `start` |
| `down` | stops and removes the containers, the data is kept |
| `shutdown` | removes the containers, the data and the settings |
| `backup`, `restore` | the settings to `*.bak` and the database to `backup/rethinkdb.tar.gz`, and back; `backup` stops the database and the STF units for the copy (the UI and the devices are unavailable meanwhile) and starts them again, a database being written is not copied consistently |
| `version` | the version of MCloud, the tag of the STF image |
| `node-invite <label> <address> [<minutes>]` | an invite of a node: prints the join string once, see [Nodes](#nodes) |
| `nodes [list]`, `nodes check <label>`, `nodes revoke <label>`, `nodes delete <label>` | the nodes, the diagnostics of a node, the revocation of a node, the removal of a revoked node, see [Nodes](#nodes) |

## Configuration

`./zebrunner.sh setup` writes the settings from the `*.original` files, `./zebrunner.sh restart` applies their changes. The next setup keeps every value of the previous `.env` and `variables.env`, also the ones changed by hand and the variables added to them (e.g. `COMPOSE_PROJECT_NAME` of `.env`, which names the volume of the database, or `STF_SESSION_TTL_SECONDS` of `variables.env`), but the ones it writes itself: `STF_URL` and `STF_PORT` (the protocol, host and port of its answers), `NODES_HOST`, the sign-in (`AUTH_SYSTEM`, `AUTH_URL`, `OAUTH_CALLBACK_URL`, the `ZEBRUNNER_*` URLs of Zebrunner CE) and the image tags `TAG_*` of `.env.original`, the images of the release (see [Upgrade](#upgrade)). The previous values are the defaults of its questions (the admin of `STF_ADMIN_*` too), the generated secrets are kept. A value with other characters than letters, digits and `_./:@%+,=-` is written in single quotes.

`.env`, the settings of `docker-compose.yml`:

| Variable | Default | Description |
| --- | --- | --- |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud: the protocol, host and port of the setup |
| `STF_PORT` | `8082` | the port of `stf-proxy` on the host |
| `AGENTS_ADDRESS` | `0.0.0.0` | the address of the host the ports of the nodes are published on (ZeroMQ of STF and the grid, see [Firewall](#firewall)) and the host of the join string: the LAN address of the server for the nodes in its network or on the server itself; `0.0.0.0` publishes them on every address and gives the nodes the host of `STF_URL`, `start` warns about it; the value of the previous setup is kept |
| `NODES_HOST` | `localhost` | written by `setup` and `start`, not set by hand: `AGENTS_ADDRESS`, the host of `STF_URL` for `0.0.0.0`; the host of the join string and of the ZeroMQ endpoints `stf-api` gives the nodes (`--nodes-connect-*` in `docker-compose.yml`) |
| `ADB_RELAY` | `false` | `true`: `adb-relay` relays the remote debug ports of the Android devices of the nodes, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay); the value of the previous setup is kept |
| `ADB_RELAY_PORTS` | | `adb-relay` relays the ports of this range only, `<first>-<last>` (e.g. `7400-7999`): the range opened in the firewall; empty: any port; the value of the previous setup is kept |
| `ADB_RELAY_SYNC_SECONDS` | `300` | `adb-relay` reads the devices of the nodes every these seconds: a new device is relayed within this time (at once after `./zebrunner.sh restart`); the value of the previous setup is kept |
| `LOG_MAX_SIZE`, `LOG_MAX_FILE` | `50m`, `5` | the rotation of the logs of every service (the json-file driver of docker): the size of a file and the number of the files; the values of the previous setup are kept |
| `TAG_NGINX` | `1.31.7` | the tag of `nginx` |
| `TAG_SELENIUM_HUB` | `3.1-develop-latest` | the tag of `public.ecr.aws/zebrunner/mcloud-grid`: on `develop` the newest image of the `develop` of mcloud-grid, a release has its version |
| `TAG_RETHINKDB` | `2.4.3` | the tag of `rethinkdb` |
| `TAG_STF` | `3.1-develop-latest` | the tag of `public.ecr.aws/zebrunner/stf`: on `develop` the newest image of the `develop` of zebrunner/stf, a release has its version |
| `AUTH_SYSTEM` | `auth-mock` | the sign-in unit of STF: `auth-mock`, `auth-oauth2` or `auth-ldap` of the [setup](#sign-in), `auth-zebrunner` in [Zebrunner CE](#zebrunner-ce) by default |
| `AUTH_URL` | `auth/mock/` | the path of the sign-in: `auth/mock/`, `auth/oauth/`, `auth/ldap/`, `auth/zebrunner/` |

`variables.env`, the settings of the STF units and of the grid:

| Variable | Default | Description |
| --- | --- | --- |
| `SECRET` | generated | the secret of the sessions and the access tokens of STF; the setup generates it once, a change of it ends the sessions and invalidates the access tokens (`STF_TOKEN` too) |
| `STF_STORAGE_TOKEN` | generated | the internal token of the STF units: the storage, the triproxies and the internal routes of the registry of the nodes; the nodes use their own tokens |
| `STF_TOKEN` | | the access token of an admin of STF: the grid reserves the devices and verifies the tokens of the nodes with it, the [node commands](#commands-of-the-nodes) and `adb-relay` read the registry of the nodes with it |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud, also the one the enrollment gives the nodes |
| `STF_ROOT_GROUP_NAME` | `MCloud` | the root group of STF |
| `STF_ADMIN_NAME`, `STF_ADMIN_EMAIL` | `admin`, `admin@zebrunner.com` | the administrator of STF, the owner of the root group |
| `ZEBRUNNER_LOGIN_URL`, `ZEBRUNNER_USERINFO_URL` | | the endpoints of Zebrunner IAM for `auth-zebrunner`, set by the setup of Zebrunner CE |
| `STF_AUTH_MOCK_USE_BASIC_AUTH`, `STF_AUTH_MOCK_BASIC_AUTH_USERNAME`, `STF_AUTH_MOCK_BASIC_AUTH_PASSWORD` | `true`, `mcloud`, generated | the shared user and password in front of the mock sign-in |
| `OAUTH_AUTHORIZATION_URL`, `OAUTH_TOKEN_URL`, `OAUTH_USERINFO_URL`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_SCOPE`, `OAUTH_DOMAIN` | | the OAuth2 sign-in, asked by the setup; `OAUTH_CALLBACK_URL` is `<STF_URL>/auth/oauth/callback` |
| `LDAP_URL`, `LDAP_BIND_DN`, `LDAP_BIND_CREDENTIALS`, `LDAP_SEARCH_DN`, `LDAP_SEARCH_FIELD` | | the LDAP sign-in, asked by the setup |
| `RETHINKDB_PORT_28015_TCP` | `tcp://rethinkdb:28015` | the database of STF |
| `RETHINKDB_ENV_AUTHKEY` | generated | the password of the `admin` of RethinkDB the STF units connect with, `stf-migrate` sets it in the database |
| `STF_ZMQ_CURVE_SERVER_SECRET_KEY`, `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY` | generated | the CURVE key pair of the triproxies of STF, the enrollment gives the public key to the node |
| `STF_ZMQ_CURVE_SECRET_KEY` | generated | the CURVE key of the STF units |
| `STF_NODES_API_URL` | `http://stf-api:3000` | the API the triproxies and the storage read the keys and the tokens of the nodes from (every 5 seconds) with `STF_STORAGE_TOKEN`; `stf-proxy` refuses its internal routes (`/api/v1/zebrunner/nodes`) |

More settings of STF (e.g. `STF_SESSION_TTL_SECONDS`, the lifetime of a session, or `STF_STORAGE_TEMP_DOWNLOAD_ALLOW`, the private networks the apps may be installed from by URL) are described in [ZEBRUNNER.md of STF](https://github.com/zebrunner/stf/blob/develop/ZEBRUNNER.md#configuration). The settings of the grid (e.g. `NODE_ALLOWED_NETWORKS`, `MAX_NEW_COMMAND_TIMEOUT`, `MCLOUD_LOG_LEVEL`) are described in [mcloud-grid](https://github.com/zebrunner/mcloud-grid#configuration), they go to `environment` of `mcloud-grid` in `docker-compose.yml`.

### Sign-in

The interactive setup asks the sign-in of STF; Zebrunner CE signs in through Zebrunner IAM (`auth-zebrunner`) by default, see [Zebrunner CE](#zebrunner-ce). The values the setup asks are written quoted into `variables.env` (quotes and backslashes are not supported) and are the defaults of the next setup.

| Sign-in | Who is the user | The setup asks |
| --- | --- | --- |
| `mock` (default) | anyone who knows the shared user and password (basic authentication) types a name and an email: whoever knows the name and the email of the admin (`STF_ADMIN_*`) signs in as the admin, so share the password with the trusted users only | nothing, the password is generated and printed |
| `oauth2` | the user of an OpenID Connect / OAuth2 provider (Google, Azure AD, Keycloak, GitLab, ...): an email of `OAUTH_DOMAIN` that the provider does not report as unverified; the admin is the user with the email `STF_ADMIN_EMAIL` | the authorization, token and user info URLs, the client of MCloud at the provider (its redirect URL is `<STF_URL>/auth/oauth/callback`), the scope (`openid email`), the domain |
| `ldap` | the user of the directory with its password | the URL, the bind DN and password (empty for an anonymous search), the search DN and the attribute of the user name (`uid`) |

### https

`./zebrunner.sh setup` with the `https` protocol turns on the ssl of `stf-proxy` with the certificate of the host: put it into `configuration/stf-proxy/ssl/ssl.crt` and its key into `configuration/stf-proxy/ssl/ssl.key` (PEM). Without them the setup warns and goes on, but `./zebrunner.sh start` starts nothing until they are there (nginx of `stf-proxy` does not start without them); the setup fails for a key of another certificate and for the self-signed pair the repository had (its private key is public), then nothing but the answers is written: they are the defaults of the next setup. Zebrunner CE gives its own certificate (`nginx/ssl` of Zebrunner CE, its nginx is in front of `stf-proxy`): the setup copies it and warns when it is missing or the self-signed one of the repository of Zebrunner CE. `shutdown` keeps the certificate. `stf-proxy` passes the scheme of the client to STF (`X-Forwarded-Proto`, the one of a proxy in front of it when there is one), so the session cookie is `Secure` behind https. The ssl settings allow TLS 1.2 and 1.3 only. The nodes trust the certificate by its pin, a self-signed one is fine for them; the storage plugins of STF (`stf-storage-plugin-image`, `stf-storage-plugin-apk`) fetch the files from `STF_URL` and need a certificate Node.js trusts (a public CA), otherwise the resizing of the screenshots and the install of the apps fail with `self-signed certificate` in their logs.

### Zebrunner CE

[Zebrunner CE](https://zebrunner.github.io/community-edition) runs `./zebrunner.sh setup` of its `mcloud` folder with `ZBR_INSTALLER=1` and its settings: the URL of Zebrunner CE, its nginx is in front of `stf-proxy` (its port `STF_PORT` is `8082`, the port of Zebrunner CE belongs to its nginx), its certificate, the sign-in through Zebrunner IAM. `./zebrunner.sh setup` run in the `mcloud` folder of Zebrunner CE keeps them (from `backup/settings.env` of the last setup of Zebrunner CE) and asks only the admin and the sign-in: `zebrunner` (Zebrunner IAM), `mock`, `oauth2` or `ldap`; the setup of Zebrunner CE keeps that sign-in. Restart the services after it: `./zebrunner.sh restart`.

### Security headers

`stf-proxy` adds `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` and `Content-Security-Policy: frame-ancestors 'self'` to every response and removes `X-Powered-By`: MCloud is not embedded into the pages of other sites. A site that frames MCloud (e.g. another host of Zebrunner) needs `frame-ancestors 'self' https://<host>` instead and no `X-Frame-Options` in `configuration/stf-proxy/nginx.conf`.

### Authentication of the nodes

The nodes connect to ZeroMQ of STF (the triproxies), their Appium nodes register in the grid, their devices upload to the storage of STF. None of them has an authentication of its own: anyone who reaches their ports reads the events of all the devices or sends commands to them, and an Appium node registered in the grid gets the sessions of its device with their capabilities (the personal `zebrunner:STF_TOKEN` too). So every node has an identity of its own, given by its [enrollment](#enrollment) and kept by STF in its registry of the nodes:

- the triproxies let in the STF units and the CURVE keys of the active nodes only ([ZeroMQ of STF](https://github.com/zebrunner/stf/blob/develop/ZEBRUNNER.md#zeromq)), the traffic is encrypted; `./zebrunner.sh setup` makes the keys of the server (X25519, as `stf curve-keygen`) with openssl or, where it has no X25519, with `patch/curve_keygen.py`;
- the grid registers an Appium node only with the token of an active node, which STF verifies for the address of that node ([Node registration of mcloud-grid](https://github.com/zebrunner/mcloud-grid#node-registration)), and sends the token with its requests to it: the Appium of a device answers the grid only, the devices are used through `/mcloud/wd/hub` and reserved in STF;
- STF binds a device to its node only with a proof of the token of the node from the address of the node, and refuses the registration of any other device;
- the storage of STF accepts the uploads of the devices with the token of an active node only;
- RethinkDB has a password, `RETHINKDB_ENV_AUTHKEY`, its web console is off and its port is not published: only the STF units of the server use the database.

The nodes need mcloud-agent, mcloud-grid and STF of the same MCloud release.

### Screens of the devices

The screen of a device is a WebSocket of its STF provider on the node, which the browser opens through `stf-proxy`: `/d/<address of the node>/<serial>/<port>/`, on a port 1024-65535. `stf-proxy` asks `stf-api` first (`auth_request` of `/api/v1/zebrunner/screen-auth` with the session cookie or the access token of the request and its URI in `X-Original-URI`, no other header of the user); `stf-api` allows it (`204`) only when the user is signed in (`401` otherwise) and uses the device (or is an admin of STF), the device is bound to an active node whose registered address is `<address of the node>` and `<port>` is the screen port of the device; anything else gets `403`. `stf-proxy` passes only the headers of the WebSocket to the node: never the session cookie, the `Authorization` header, `X-Stf-Internal-Token` or another `X-Stf-*` header of the user.

### Nodes in a private network

The nodes may be in a private network (LAN) with the MCloud server, only the server is public. The address of the invite of a node is its LAN address (or a LAN host name), its `STF_PROVIDER_HOST`, and `AGENTS_ADDRESS` of `.env` is the LAN address of the server:

- the screens: browser -> `wss://<public host>/d/<address of the node>/...` -> `stf-proxy` -> the node over the LAN;
- the tests: client -> `mcloud-grid` -> the Appium node of the node over the LAN; the hub registers an Appium node only when it reaches `http://<address of the node>:<Appium port>`, otherwise it answers the registration with `500` and logs `Node <url> is not reachable from the hub`;
- the enrollment, ZeroMQ of STF, the grid registration, the storage and S3 are outbound connections of the node, to the host of the join string (`AGENTS_ADDRESS`).

A public address of a node as its address, or a public name of the server for the node, often fails inside the LAN (no NAT hairpin): neither the hub nor `stf-proxy` connects to it, or the node does not reach the server. Only the remote debug of a user (`adb connect`) needs a route from the user to the node, or [the adb relay](#remote-debug-through-the-adb-relay).

### Remote debug through the adb relay

STF shows the remote debug of an Android device as `adb connect <host>:<port>`: the host is the address of its node (or `REMOTE_CONNECT_HOST` of mcloud-agent), the port is the remote debug port of the device on its node, `connect_port` of the device in mcloud-agent or `min_port` + 1 by default (its `min_port` is its screen). A node in a private network, where only the server of MCloud is public, works through the server, but the users do not reach the ports of its devices. The optional `adb-relay` relays the remote debug ports through the server:

1. Set `ADB_RELAY=true` of `.env` and `ADB_RELAY_PORTS` to the range of the remote debug ports the server relays, the one opened in its firewall (e.g. `ADB_RELAY_PORTS=7400-7999`).
2. Run `./zebrunner.sh restart`: it starts `adb-relay` and warns about an empty `STF_TOKEN` of `variables.env` and the invalid settings.
3. Set `REMOTE_CONNECT_HOST` of mcloud-agent of these nodes to the public name of MCloud (the host of `STF_URL`) and deploy it again: STF shows `adb connect <REMOTE_CONNECT_HOST>:<port>` then (mcloud-agent passes it to [mcloud-device](https://github.com/zebrunner/mcloud-device)). `connect_port` of a device in mcloud-agent is optional: it sets the remote debug port, e.g. to keep the ports of the devices in `ADB_RELAY_PORTS`.
4. Open `ADB_RELAY_PORTS` in the firewall of the server for the users, see [Firewall](#firewall), and the remote debug ports of the devices of the nodes for the server.

`adb-relay` reads the Android devices of the active nodes from the STF API (`GET /api/v1/nodes/relay`) every `ADB_RELAY_SYNC_SECONDS` (`300`) and relays the remote debug port of every one of them (`connectPort` of the device in STF) to the same port of the registered address of its node, present or not (the node refuses the port of an absent device): the address the admin gave in the invite, never an address the node or the device reports. It skips an address of the server itself or of the link (loopback, link-local, multicast), a port out of `ADB_RELAY_PORTS` and a port of MCloud (`STF_PORT`, `4446`, `7160`, `7250`, `7260`, `7270`); the screen ports are never relayed. A port of two devices is relayed for neither of them, the log names both: change `connect_port` of one of the devices in mcloud-agent. As the absent devices stay relayed, the servers of nginx change only when a device is added to STF, removed from it or gets another port: then `adb-relay` reloads nginx, the open adb sessions go on. `docker logs adb-relay` lists the relayed devices and the skipped ones with the reason whenever they change, and every session: the client, the port, the node, the bytes and the duration.

STF is the single source of truth of the nodes and of their devices: the nodes need no channel and no secret to the relay, and after a restart of the relay, of STF or of a node the relay comes back to the devices of STF by itself. A new device is relayed within `ADB_RELAY_SYNC_SECONDS`, or at once after `./zebrunner.sh restart` (or `docker restart adb-relay`).

The relay reads the API with `STF_TOKEN` of `variables.env`, an access token of an admin: `./zebrunner.sh setup`, `start` and `restart` copy only this token into `configuration/adb-relay/stf-token` (readable for its owner only, empty with `ADB_RELAY=false`), the only secret of MCloud the relay on the network of the host gets, given to curl on its stdin; the relay reads it on every sync, so a new token needs `./zebrunner.sh start`, not a restart of the relay. It reaches the API through `stf-proxy` on `127.0.0.1:STF_PORT` of the server with the scheme of `STF_URL` (the certificate of the public name is not checked on the loopback address); when the API fails, the relay keeps its devices.

`adb-relay` is the nginx of `stf-proxy` (`TAG_NGINX`) in the network of the host (`network_mode: host`: a port per device, not published one by one) with `configuration/adb-relay/adb-relay.sh`, the sync: it listens on every relayed port on every address of the server and connects to the same port of the node; an idle session ends after 24 hours. `./zebrunner.sh` starts it (the compose profile `adb-relay`) only with `ADB_RELAY=true`; `stop`, `down`, `restart` and `shutdown` take it along also after it is turned off: run `./zebrunner.sh restart` after a change of the `ADB_RELAY*` settings (also in Zebrunner CE). On macOS the network of the host of Docker Desktop is the one of its VM: the ports need its host networking (Settings, Resources, Network).

The relay has no authentication of its own, it makes its ports public as they are. The remote debug port of a device listens only while a user of STF uses the device (the Remote debug of its dashboard starts it) and accepts an adb client with an adb key of that user only (STF, Settings, ADB keys): an unknown key makes STF ask that user to add it, add only your own keys.

### Firewall

The ports of the host and who needs them; close the others:

| Port | Service | Clients |
| --- | --- | --- |
| `STF_PORT` | `stf-proxy` | the users, the tests, the nodes (the enrollment, the storage, the diagnostics) |
| `7160`, `7250`, `7260`, `7270` (`AGENTS_ADDRESS`) | ZeroMQ of STF (`stf-triproxy-app`, `stf-triproxy-dev`) | the nodes |
| `4446` (`AGENTS_ADDRESS`) | `mcloud-grid` | the nodes (Appium registers to the grid); the tests use `/mcloud/wd/hub` of `STF_PORT` |
| `ADB_RELAY_PORTS` | `adb-relay` (optional) | the users: `adb connect` of the remote debug of the devices of the nodes in a private network, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay) |

`AGENTS_ADDRESS` publishes the ports of the nodes on one address of the host, the one the nodes reach (the join string gives it to them, the host of `STF_URL` for `0.0.0.0`). A node publishes the ports of its devices (the screens, Appium, the remote debug) for the server: `stf-proxy` serves the screens to the users, the grid connects to Appium, see [mcloud-agent](https://github.com/zebrunner/mcloud-agent).

### Basic authentication of the grid

See [configuration/stf-proxy/htpasswd](configuration/stf-proxy/htpasswd/README.md).

### Files and secrets

`variables.env`, `backup/settings.env`, the key of the certificate (`configuration/stf-proxy/ssl/ssl.key`), the access token of the auto mode of `adb-relay` (`configuration/adb-relay/stf-token`), the archive of the database (`backup/rethinkdb.tar.gz`) and their backups hold the secrets of the deployment: `setup`, `start`, `backup` and `restore` keep them readable for their owner only (`600`). Run `zebrunner.sh` as the user of the deployment; a `sudo ./zebrunner.sh` gives the files it writes back to the owner of the folder.

## Nodes

A node is a host of [mcloud-agent](https://github.com/zebrunner/mcloud-agent) with its devices. The admin invites a node by its label and its address, the node joins with the invite and gets an identity of its own: its CURVE key for ZeroMQ and its token for the grid and the storage, kept by STF in its registry of the nodes. The devices of a node are bound to it, the screens and the remote debug of them go to its registered address only, and a node is revoked alone.

### Enrollment

The server needs https with the certificate of the host ([https](#https)), the services running, `STF_TOKEN` of `variables.env` of an admin of STF and `AGENTS_ADDRESS` of `.env` the nodes reach ([Run](#run)).

1. On the server: `./zebrunner.sh node-invite <label> <address> [<minutes>]`, e.g. `./zebrunner.sh node-invite lab-1 192.168.30.2`:
   - the label is the name of the node, unique, 1-40 lower case letters, digits and `-`; `enroll`, `invites`, `relay` and `verify` are reserved by STF;
   - the address is the one the server connects to (the screens, Appium), the `STF_PROVIDER_HOST` of the node: an IPv4 address or a host name without the protocol and the port, not a loopback (`127.x`, `localhost`), `0.0.0.0`, link-local or multicast one, unique among the nodes; a node on the server itself has the LAN address of the server, see [Devices on the MCloud server](#devices-on-the-mcloud-server);
   - the invite is valid 60 minutes, `<minutes>` sets 1-1440, and enrolls once.
2. It prints the join string once, a secret: copy it to the node over a trusted channel.
3. On the node: `./zebrunner.sh join` of mcloud-agent reads the join string from stdin or a hidden prompt (never from its arguments), checks the certificate of `stf-proxy` by the pin, enrolls the key of the node with the invite and writes the token and the settings of MCloud into the settings of mcloud-agent; then `./zebrunner.sh ansible` and `zebrunner-farm restart` deploy them.
4. `./zebrunner.sh nodes` shows the node `active`, with the time the grid last saw it; `./zebrunner.sh nodes check <label>` checks it and its devices ([Diagnostics](#diagnostics)).

A new invite of an enrolled label enrolls the node again: its new key and token replace the old ones at once, the regular way to rotate them (the devices bind to it again on their next registration, after `zebrunner-farm restart`). A new invite of a label also cancels the earlier invites of that label that are not used yet.

### The join string

```text
mcloud-join://<host>:<port>?label=<label>&grid=<grid host>:<grid port>&pin=<pin>&token=<invite>
```

| Part | Value |
| --- | --- |
| `<host>` | `NODES_HOST`: `AGENTS_ADDRESS` of `.env`, the host of `STF_URL` when it is `0.0.0.0` (every address) |
| `<port>` | `STF_PORT`, the port of `stf-proxy`: the enrollment, the storage, the API |
| `label` | the label of the node |
| `grid` | `<host>:4446`, the published port of the grid (`docker-compose.yml`) |
| `pin` | base64 of the SHA-256 of the public key (DER SubjectPublicKeyInfo) of `configuration/stf-proxy/ssl/ssl.crt`, as `curl --pinnedpubkey 'sha256//<pin>'` takes it, with `+`, `/` and `=` percent-encoded (`%2B`, `%2F`, `%3D`); `node-invite` also prints it as it is |
| `token` | the invite, `mci1.<secret>` |

The parameters are in this order and URL-safe. The node takes the ports of ZeroMQ from the answer of the enrollment (`stf-api` gives `tcp://<NODES_HOST>:<port>`) and their host from the join string: the triproxies publish `7160`, `7250`, `7260` and `7270` on `AGENTS_ADDRESS`, the same host, see [Firewall](#firewall). The answer also has the public URL of MCloud for the node, `STF_URL` of `variables.env`. A new certificate of `stf-proxy` changes the pin of the next invites.

### Commands of the nodes

| Command | What it does |
| --- | --- |
| `./zebrunner.sh node-invite <label> <address> [<minutes>]` | an invite of a node, the join string is printed once |
| `./zebrunner.sh nodes`, `nodes list` | the nodes of the registry: the label, the address, `active` or `revoked`, the time the grid last saw it, the time of its enrollment, the first characters of its key |
| `./zebrunner.sh nodes check <label>` | the diagnostics of a node, see [Diagnostics](#diagnostics) |
| `./zebrunner.sh nodes revoke <label>` | revokes a node and restarts `stf-triproxy-app` and `stf-triproxy-dev`, which ends its open ZeroMQ sessions (the other nodes reconnect at once) |
| `./zebrunner.sh nodes delete <label>` | removes a revoked node from the registry: its label and its address are free again |

They call the STF API through `stf-proxy` on `127.0.0.1:STF_PORT` of the server (with the scheme of `STF_URL`, the certificate is not checked on the loopback address) with `STF_TOKEN` of `variables.env`, which goes to curl on its stdin and is never printed. The API answers an error without details, `docker logs stf-api` has them.

### Diagnostics

`./zebrunner.sh nodes check <label>` on the server shows:

- the record of the node: `active` or `revoked`, its address, the time of its enrollment and the time the grid last saw it (`-`: no Appium of the node registered with its token yet);
- the devices STF binds to the node, with the platform, present or not, the screen port and the remote debug port;
- for every present device, whether `stf-proxy` connects to `<address of the node>:<screen port>` (from inside the container, the path of the screens): `reachable` or `NOT REACHABLE`.

It exits with `1` and a hint when something is wrong: an unknown or revoked node, a node the grid has not seen, no device bound to the node (the devices register with the token of the node from its address, `docker logs stf-processor001` names the refused registrations), `stf-proxy` not running, a screen the server does not reach (the address of the invite is not the one the server reaches the node at, the firewall of the node, a public address inside the LAN, NAT hairpin). `./zebrunner.sh doctor` of mcloud-agent checks the same from the node with its token (`GET /api/v1/nodes/self`, limited by `stf-proxy` to 30 a minute per address): the enrollment, the address, the devices STF knows and the deployed devices that are missing in STF.

### Revocation

Revoke a node that is lost or given away, whose host or settings may be read by others, or that is not needed any more: `./zebrunner.sh nodes revoke <label>`. At once the triproxies refuse its key, the storage and STF its token, its devices lose their binding (no screen, no remote debug relay); the grid drops its Appium nodes on the next check of their token (every 60 seconds). A new invite of the label enrolls it again with a new key and token; `nodes delete` removes it.

### Devices on the MCloud server

The server of MCloud may be a node too: mcloud-agent on the same machine, its device containers in the docker network `infra` of MCloud.

1. Set `AGENTS_ADDRESS` of `.env` to the LAN address of the machine (not `127.0.0.1`, not `0.0.0.0`) and run `./zebrunner.sh restart`: the ports of the nodes are published on it and the join string has it; the device containers reach `stf-proxy`, the grid and the triproxies there. With `0.0.0.0` the node gets the public name of `STF_URL`, which the machine often does not reach from inside (NAT hairpin): `start` warns about it.
2. Invite the node with the same LAN address: `./zebrunner.sh node-invite <label> <LAN address>`; a loopback address, `localhost` or `0.0.0.0` is refused, the server connects to the screens and Appium of the node at that address.
3. The ports of the devices in mcloud-agent (`appium_port`, `adb_port`, `min_port`-`max_port`, `connect_port`) must not be the ports of MCloud: `STF_PORT`, `4446`, `7160`, `7250`, `7260`, `7270` and the ports of `ADB_RELAY_PORTS` (with `ADB_RELAY=true`); `./zebrunner.sh doctor` of mcloud-agent checks the collisions.
4. `./zebrunner.sh nodes check <label>` shows whether `stf-proxy` reaches the screens of the devices.

### Security

What the enrollment gives:

- every node has its own key and token (`mcn1.<label>.<secret>`, 256 random bits): a node is revoked alone, the others go on; STF keeps the SHA-256 of the tokens and the invites only;
- an invite has 256 random bits, is used once (also by two parallel enrollments), expires (60 minutes by default) and is bound to the label and the address the admin chose; the enrollment is limited in `stf-proxy` to 6 a minute per client address (a burst of 3, then `429`);
- the node trusts the server by the pin of the certificate of `stf-proxy`, a self-signed certificate is fine; the join string is never an argument of a command (the process list), the server prints it once;
- the address of a node is the one of the admin, never one the node reports: the grid takes a node token only for an Appium node at that address, a device is bound to the node only with a proof of the token of the node (an HMAC) and at that address, the screens and the remote debug relay go to the registered address only, so a node cannot point the server at another host;
- the screens are served to the user of the device only, and `stf-proxy` never passes the session cookie, the access token or the `X-Stf-*` headers of the user to the node;
- `STF_TOKEN` stays on the server: the commands give it to curl on its stdin, `adb-relay` gets it alone;
- `stf-proxy` refuses the internal routes of the registry (`/api/v1/zebrunner/nodes`, the keys and the tokens for the triproxies and the storage on `stf-api:3000`) with `403`.

The risks that stay:

- the join string is a secret until it is used or expires: whoever uses it first enrolls as that node (still bound to its address). Send it over a trusted channel, keep the validity short and revoke a node enrolled by surprise (`nodes` shows the key and the time it was last seen);
- whoever is root on a node, or in its docker group, has its key and token and acts as that node (its devices, the sessions of its devices, its uploads) until it is revoked, not as another node;
- the server reaches the screens and Appium of a node over plain HTTP and WebSocket at its address; only ZeroMQ is encrypted. Someone who takes the address of a node in its network (ARP or DNS spoofing) sees that traffic: keep the nodes in a trusted network or a VPN;
- the limits of `stf-proxy` are per client address: behind another proxy all the clients share one, and many addresses only slow down; the 256 bits of an invite keep the guessing hopeless anyway;
- a revocation ends the open ZeroMQ sessions by a restart of the triproxies (all the nodes reconnect), the grid drops a revoked node within 60 seconds and the storage may accept its token for up to 60 seconds (its cache);
- `STF_TOKEN` of `variables.env` is a token of an admin of STF: `variables.env` is readable for its owner only, see [Files and secrets](#files-and-secrets).

## Services

All the services but `adb-relay` (the network of the host) are in the external docker network `infra`, which `./zebrunner.sh start` creates.

| Service | Image | What it does |
| --- | --- | --- |
| `stf-proxy` | `nginx` | the entry point on `STF_PORT`: STF, the grid under `/mcloud`, the static files of the grid console, the screens of the devices |
| `mcloud-grid` | `public.ecr.aws/zebrunner/mcloud-grid` | the Selenium/Appium hub of the devices, also on the port `4446` of the host (`AGENTS_ADDRESS`) |
| `rethinkdb` | `rethinkdb` | the database of STF, the volume `stf-db-volume`, with the password `RETHINKDB_ENV_AUTHKEY` and without its web console, not published on the host |
| `stf-migrate` | `public.ecr.aws/zebrunner/stf` | creates and updates the tables of the database (the registry of the nodes too), the other STF units start after it |
| `stf-app`, `stf-auth`, `stf-api`, `stf-websocket` | `public.ecr.aws/zebrunner/stf` | the UI, the sign-in, the REST API (the registry of the nodes too) and the websocket of STF |
| `stf-processor001`, `stf-reaper`, `stf-api-groups-engine` | `public.ecr.aws/zebrunner/stf` | the device events (the binding of the devices to their nodes), the heartbeats and the groups of STF |
| `stf-triproxy-app`, `stf-triproxy-dev` | `public.ecr.aws/zebrunner/stf` | the message brokers of the STF units and of the devices, the ports `7160` and `7250`-`7270` of the host (`AGENTS_ADDRESS`) |
| `stf-storage-temp`, `stf-storage-plugin-apk`, `stf-storage-plugin-image` | `public.ecr.aws/zebrunner/stf` | the storage of the apps and screenshots, the volume `stf-temp-volume`; for the STF units and the tokens of the nodes only |
| `adb-relay` | `nginx` | optional, with `ADB_RELAY=true` only: the TCP relay of the remote debug ports of the devices of the nodes in a private network, in the network of the host, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay) |

Every service has a healthcheck (`docker ps` shows `unhealthy` for one that stopped answering): the STF units with an HTTP port and the triproxies (a TCP connection), `stf-proxy`, `rethinkdb`, `adb-relay` (nginx listens on its ports), `mcloud-grid` (the one of its image), and the units without a port, `stf-processor001`, `stf-reaper` and `stf-api-groups-engine`: they are healthy while they are connected to their ZeroMQ brokers and to RethinkDB (`stf-migrate` runs once); `stf-proxy` starts once `stf-app` is healthy. Docker restarts a service when it exits, not when it is unhealthy. The logs of every service are rotated (`LOG_MAX_SIZE`, `LOG_MAX_FILE`).

## Endpoints

| Endpoint | Content |
| --- | --- |
| `/stf` | the UI of STF |
| `/api/v1/` | the REST API of STF, with an access token |
| `POST /api/v1/nodes/enroll` | the enrollment of a node with its invite, limited to 6 a minute per address (a burst of 3, then `429`), see [Nodes](#nodes) |
| `GET /api/v1/nodes/self` | the record of a node and its devices, with the token of the node (`./zebrunner.sh doctor` of mcloud-agent), limited to 30 a minute per address (a burst of 10, then `429`) |
| `/d/<address of the node>/<serial>/<port>/` | the screen of a device, see [Screens of the devices](#screens-of-the-devices) |
| `/mcloud/wd/hub` | the Selenium/Appium hub URL |
| `/mcloud/playwright/<session id>` | the WebSocket of a Playwright session of the grid, see [Playwright](#playwright) |
| `/mcloud/grid/console` | the grid console with the devices |
| `/mcloud/grid/admin/DevicesServlet` | the devices of the grid as JSON: their status and sessions |
| `/mcloud/grid/admin/AllSessionsServlet` | the active sessions as JSON |
| `/mcloud/grid/admin/MetricsServlet` | the Prometheus metrics of the grid |
| `POST /mcloud/grid/admin/TerminateSessionServlet` | terminates the session of a device, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#terminating-a-session) |

## Playwright

[Playwright](https://playwright.dev/docs/api/class-android) tests run on the Android devices of the farm, from any machine that reaches MCloud (e.g. a CI runner, no adb there). It is an option of the farm, off by default: set `PLAYWRIGHT_ENABLED=true` in `variables.env` and run `./zebrunner.sh restart` (`./zebrunner.sh setup` keeps the value). Without it the grid refuses the Playwright sessions at once (`Playwright sessions are not enabled on this grid`, no device is reserved) and their WebSocket with `501`; the other sessions are not affected.

The test starts an Appium session of the `Playwright` automation through the grid, which queues it, reserves a device and records its video as for any session, and connects Playwright to the WebSocket of the session:

```js
// POST /mcloud/wd/hub/session {"capabilities": {"alwaysMatch": {"platformName": "Android", "appium:automationName": "Playwright"}}}
const device = await _android.connect(`wss://mcloud.example.com/mcloud/playwright/${sessionId}`);
const context = await device.launchBrowser(); // Chrome of the device
// ... the tests; then DELETE /mcloud/wd/hub/session/<sessionId>
```

[examples/playwright](examples/playwright) has the fixtures of `@playwright/test`: every worker takes a device (`MCLOUD_DEVICES` workers, the devices in parallel) and returns it after its tests, the tests get Chrome of the device as `page` and `context`, the device itself as `device`; the capabilities of the grid select the devices (`MCLOUD_CAPS`, e.g. `{"appium:platformVersion": "14+"}`). Run it from CI:

```bash
cd examples/playwright && npm ci && MCLOUD_URL=https://mcloud.example.com MCLOUD_DEVICES=2 npx playwright test
```

- Any Playwright version works: the node serves the version of the client and installs another one on its first use (the device host needs the npm registry), see [zebrunner/appium](https://github.com/zebrunner/appium#playwright).
- Chrome of a device that is neither rooted nor debuggable reads the command line of Playwright only with `chrome://flags/#enable-command-line-on-non-rooted-devices` enabled: enable it once on such devices.
- The session lives as long as its WebSocket; a client that is gone leaves it to the timeout of the grid, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#playwright).
- Android only: Playwright has no automation of Safari of iOS devices.

## Upgrade

An MCloud release works with mcloud-agent of the same release only (the images of the nodes, the enrollment): update the server and all the nodes together.

1. Update the repository: `git pull`.
2. Run `./zebrunner.sh setup`: it keeps the settings of the previous setup and generates the missing ones.
3. Restart the services: `./zebrunner.sh restart`; `stf-migrate` updates the tables of the database.
4. Update mcloud-agent of every node to the same release, see its README; a node of a release without the enrollment is enrolled as a new one ([Enrollment](#enrollment)).

## Troubleshooting

`docker logs <service>` shows the log of a service, `docker ps` the unhealthy ones (see [Services](#services)); `./zebrunner.sh nodes check <label>` on the server and `./zebrunner.sh doctor` of mcloud-agent on the node check a node ([Diagnostics](#diagnostics)).

| Symptom | Cause and fix |
| --- | --- |
| `./zebrunner.sh start` fails to pull: `denied: Your authorization token has expired` or `403 Forbidden` from `public.ecr.aws` | an expired login to public.ecr.aws in `~/.docker/config.json` of the user: the images are public, `docker logout public.ecr.aws` (or log in again: `aws ecr-public get-login-password --region us-east-1 \| docker login --username AWS --password-stdin public.ecr.aws`) |
| the pull fails with `manifest unknown` | the tag of `TAG_*` of `.env` is not published: the tags of `.env.original` of the current MCloud |
| `./zebrunner.sh node-invite` or `nodes` fails: `stf-proxy does not answer`, `not a valid access token`, `not of an admin`, `no registry of the nodes` | the commands call the STF API through `stf-proxy` on `127.0.0.1:STF_PORT` of the server with `STF_TOKEN` of `variables.env`: the services run (`./zebrunner.sh start`), `STF_TOKEN` is an access token of an admin of STF, `TAG_STF` is the STF of this MCloud release; the API answers the details in `docker logs stf-api` only |
| `./zebrunner.sh node-invite` or `nodes` fails: `the STF API answered 500 to STF_TOKEN of variables.env itself` | STF cannot read the token (nothing in `docker logs stf-api`): it was made with another `SECRET` of `variables.env` or its user is removed. A new setup in a new folder makes a new `SECRET`, while docker compose keeps the database in the volume `<folder>_stf-db-volume` named by the folder: of a folder removed without `./zebrunner.sh shutdown` or of another folder of the same name (e.g. `mcloud` of Zebrunner CE), the setup warns about it. Sign in to STF as an admin, generate an access token (Settings, Keys), set it as `STF_TOKEN` and `./zebrunner.sh restart`; or keep the `SECRET` of that MCloud in `variables.env` |
| `./zebrunner.sh start` (`stop`, `down`, `restart`, `backup`, `restore`, `shutdown`) did nothing: `the docker compose project <name> is the MCloud of <folder>` | another folder of the same name (e.g. `mcloud` of Zebrunner CE) runs MCloud: docker compose names the projects and the volumes by the folder, the command would act on its containers and its database. One MCloud runs on a server: use that folder, or `./zebrunner.sh down` in it (its `shutdown` also removes its database), then `./zebrunner.sh start` here |
| `./zebrunner.sh start` fails: `stf-proxy serves https and needs its certificate` or `is not the key of` | the setup of https went on without the certificate, or the key is of another certificate: put the certificate and its key into `configuration/stf-proxy/ssl/`, see [https](#https), then `./zebrunner.sh start` |
| `./zebrunner.sh node-invite` fails with `The enrollment needs https of stf-proxy` | the node trusts the certificate of `stf-proxy` by its pin only: set MCloud up with https and its certificate, see [https](#https) |
| `./zebrunner.sh node-invite` refuses the address | the address is the one the server connects to: not `127.x`, `localhost`, `0.0.0.0`, link-local or multicast; a node on the server itself has the LAN address of the server, see [Devices on the MCloud server](#devices-on-the-mcloud-server) |
| `./zebrunner.sh join` of the node cannot connect to the server, or fails the pin | the node does not reach the host of the join string (`AGENTS_ADDRESS`, the host of `STF_URL` for `0.0.0.0`) on `STF_PORT`: set `AGENTS_ADDRESS` to an address the node reaches (the LAN address of the server, NAT hairpin), `./zebrunner.sh restart` and a new invite; a pin that does not match is a certificate changed after the invite (a new invite) or another server on the way |
| `./zebrunner.sh join` fails with `403` | the invite is used, expired, replaced by a newer invite of the label, or of another label: a new invite; `docker logs stf-api` tells which |
| `./zebrunner.sh join` fails with `429` | the enrollment is limited to 6 a minute per address: wait a minute; behind another proxy (e.g. the nginx of Zebrunner CE) every node has its address, the join string points to `stf-proxy` itself (`STF_PORT`) |
| `nodes check` shows no device bound to the node; the `stf` container of an Android device restarts after `Providing all 0 of 1 device(s)` | the devices register with the token of the node from its address: `STF_PROVIDER_HOST` of the node is not the address of the invite, the containers run with an old token (after a new enrollment: `./zebrunner.sh ansible` and `zebrunner-farm restart` on the node), or the node is revoked; `docker logs stf-processor001` names the refused registrations, `stf-triproxy-app` or `stf-triproxy-dev` log `Refused the ZeroMQ client <address> with the unknown key "<key>"` for a key that is not of an active node |
| the devices are in STF, not in `/mcloud/grid/console`; `nodes check` shows the node not seen by the grid | `mcloud-grid` logs why it refuses an Appium node: an invalid or revoked token of the node, or the host of the URL of the Appium node is not the address of the node (`STF_PROVIDER_HOST` of the node): enroll it again; `Node <url> is not reachable from the hub`: the grid does not reach `http://<address of the node>:<Appium port>` (the firewall of the node, a public address in the LAN, see [Nodes in a private network](#nodes-in-a-private-network)); `Could not get the device '<udid>' from STF (HTTP 401)`: `STF_TOKEN` of `variables.env` is empty or not an access token of an admin of STF (set it and `./zebrunner.sh restart`) |
| the screen of a device stays gray; `nodes check` shows `NOT REACHABLE` | `stf-proxy` does not reach `<address of the node>:<screen port>`: the address of the invite is not the one the server reaches the node at (a new invite with the right address), the firewall of the node closes the ports of its devices for the server, or a public address inside the LAN (NAT hairpin, use the LAN address) |
| the screen of a device stays gray, `/d/<node>/...` answers `403` | `stf-api` refuses it: the user does not use the device, the device is not bound to an active node, or the host or the port of the URL are not the address of its node and its screen port (see [Screens of the devices](#screens-of-the-devices)); `401`: the user is not signed in; `500`: the STF of `TAG_STF` has no `/api/v1/zebrunner/screen-auth` |
| the screenshots or the app installs of the devices fail with `401` / `403` | the storage refuses the token of the node: the node is revoked or its containers run with an old token (`./zebrunner.sh ansible` and `zebrunner-farm restart` on the node); `self-signed certificate` in the logs of `stf-storage-plugin-image` or `stf-storage-plugin-apk`: the STF units do not trust the certificate of `STF_URL`, see [https](#https) |
| `configuration/adb-relay/stf-token is not writable` | the file was written by root (`sudo ./zebrunner.sh ...`): remove it (`rm -f configuration/adb-relay/stf-token`) and `./zebrunner.sh restart`; `adb-relay` keeps the token it has until then |
| `adb connect` of STF to a device of a node in a private network times out or fails | `REMOTE_CONNECT_HOST` of mcloud-agent is not the public name of MCloud, the relay skips the port or the firewall of the server closes it, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay): `docker logs adb-relay` lists the relayed devices and the skipped ones with the reason (e.g. a port out of `ADB_RELAY_PORTS`, a port of two devices), a new device is relayed within `ADB_RELAY_SYNC_SECONDS`; it also shows the sessions and why a node refused one |
| `docker logs adb-relay` shows `The STF API ... failed` or `answered without devices` | the relay does not read the devices: `401` is an invalid `STF_TOKEN` of `variables.env` (a new access token of STF, Settings, Keys, then `./zebrunner.sh start` writes it into `configuration/adb-relay/stf-token`), `403` a token of a user that is not an admin, `404` an STF of `TAG_STF` without the registry of the nodes; a failed connection is `stf-proxy` not running or not with the scheme of `STF_URL` (http or https); the relay keeps its devices until the next successful sync |
| `adb-relay` restarts, `docker logs adb-relay` shows `bind() to 0.0.0.0:<port> failed (98: Address already in use)` | another program of the server listens on a relayed port (e.g. a device of a node on the server itself, see [Devices on the MCloud server](#devices-on-the-mcloud-server)): move the ports of the device in mcloud-agent (`connect_port`, `min_port`) or keep the port out of `ADB_RELAY_PORTS` |
| `The certificate of Zebrunner CE (../nginx/ssl/ssl.crt and ssl.key) cannot be copied` | the key of Zebrunner CE is readable for root only (e.g. written by certbot): make it readable for the user of the setup (its group and `chmod 640`) instead of `sudo ./zebrunner.sh setup` |
| a device of a gone node is not removed by Settings, Devices of STF (nothing happens) | the removing filters of the page skip the devices that are controlled, booked or annotated, and a device whose node went away during a session stays controlled: set *Controlled* (and the others) of the filters to *Any* |
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
| `make test` | `tests/zebrunner_test.sh` and `tests/utility_test.sh`: the commands of `zebrunner.sh` on a copy of the repository with `docker` and `curl` stubs (the node commands with answers of the STF API, the configuration of `stf-proxy`); `tests/adb_relay_test.sh`: the sync of `configuration/adb-relay/adb-relay.sh` with answers of the STF API and stubs | bash, openssl, Python 3 |
| `make docker` | `tests/compose_test.sh`: the setup, the start and the endpoints of the services, `adb-relay`, then their shutdown; `tests/adb_relay_docker_test.sh`: the auto mode of `adb-relay` with a fake STF API and a stand-in node (the sessions, the reload, the errors); `tests/stf_proxy_docker_test.sh`: the configuration of `stf-proxy` with a fake `stf-api` and a fake node (the decision about the screens, the headers each side gets, the internal routes, the limits of the enrollment and of the record of a node); `TAG_STF=<tag> TAG_SELENIUM_HUB=<tag> make docker` checks other images | Docker, no other MCloud on the machine |

The tests write JUnit XML into `$JUNIT_DIR` when it is set. CI (`.github/workflows/ci.yml`) runs the jobs `lint`, `tests` (Linux and macOS) and `docker` on the pushes and pull requests.

The end-to-end test of the farm (`.github/workflows/e2e.yml`, on the pushes and pull requests, every night and on demand) runs on a GitHub runner with KVM:

1. `tests/e2e/build-images.sh` builds the images of the farm with an Android device from the `develop` branches of their repositories with the tags of `.env.original` and of `mcloud-agent`; only the uploader is pulled from `public.ecr.aws/zebrunner` (`artifacts-uploader` is private). The inputs `ref` (all the repositories) and `refs` (single ones: `STF_REF=fix/x MCLOUD_AGENT_REF=feat/y`) of a manual run take other branches, as `E2E_REF` and `E2E_REFS` or `<REPOSITORY>_REF` of the script.
2. `tests/e2e/emulator.sh` starts with an Android emulator (`android-emulator-runner`) and relays its adb to the containers.
3. `tests/e2e/farm_test.sh` sets up and starts MCloud of this checkout with https (a self-signed certificate) and `AGENTS_ADDRESS` of the machine, MinIO for the artifacts and a node of `mcloud-agent` on the same machine with the emulator, enrolled with `node-invite` and `join`, then checks `nodes check`, the containers, the device in STF and in the grid, an Appium session with an app, the screen of the device in STF, the upload of a file to STF and the artifacts of the session (the video too) in S3.

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
