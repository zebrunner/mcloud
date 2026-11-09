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
- openssl with X25519 (OpenSSL 1.1.1+) or Python 3: the setup makes the [CURVE keys](#authentication-of-the-device-hosts) with them (the LibreSSL of macOS has no X25519, Python 3 is used there); `./zebrunner.sh node-invite` makes the pin of the certificate with openssl (LibreSSL too) or Python 3
- curl: the [node commands](#nodes) call the STF API with it

## Run

1. Clone [mcloud](https://github.com/zebrunner/mcloud) and set it up, provide valid protocol, hostname and port:

   ```bash
   git clone https://github.com/zebrunner/mcloud.git && cd mcloud && ./zebrunner.sh setup
   ```

2. Start the services: the setup offers it, otherwise `./zebrunner.sh start`.
3. Open `http://hostname:80/stf` (the protocol, host and port of the setup).
4. Sign in: the default mock sign-in asks the user and the password the setup printed (`STF_AUTH_MOCK_BASIC_AUTH_*` of `variables.env`), then any name and email; the setup also offers OAuth2 and LDAP, see [Sign-in](#sign-in).
5. Sign in as the admin of STF (`STF_ADMIN_*`), go to Settings, Keys and generate a new Access Token.
6. Paste the generated token into `variables.env` as `STF_TOKEN`: the grid reserves the devices with it, the [node commands](#nodes) manage the nodes with it.
7. Restart the services: `./zebrunner.sh restart`.
8. Set up the servers with Android and iOS devices (the nodes) according to [mcloud-agent](https://github.com/zebrunner/mcloud-agent), the same on Linux and macOS, and enroll every one of them: `./zebrunner.sh node-invite <label> <address>` here prints a join string, `./zebrunner.sh join` of mcloud-agent on the node takes it, see [Nodes](#nodes) (https only).
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
| `node-invite <label> <address> [<minutes>]` | an invite of a node: prints the join string for `./zebrunner.sh join` of mcloud-agent once, see [Nodes](#nodes) |
| `nodes [list]`, `nodes revoke <label>`, `nodes delete <label>`, `nodes legacy-off` | the enrolled nodes; the revocation of a node; the removal of a revoked node; the end of the manual keys and tokens of the nodes, see [Nodes](#nodes) |

## Configuration

`./zebrunner.sh setup` writes the settings from the `*.original` files, `./zebrunner.sh restart` applies their changes. The next setup writes `.env` again and keeps the values of the variables of `variables.env.original` in `variables.env` (but `STF_URL` and the `ZEBRUNNER_*` URLs, which come from the protocol, host and port); the other variables added to `variables.env` are added again after it.

`.env`, the settings of `docker-compose.yml`:

| Variable | Default | Description |
| --- | --- | --- |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud: the protocol, host and port of the setup |
| `STF_PORT` | `8082` | the port of `stf-proxy` on the host |
| `AGENTS_ADDRESS` | `0.0.0.0` | the host address of the ports the nodes connect to: ZeroMQ of STF and the grid, see [Firewall](#firewall); also the host of the join string of `./zebrunner.sh node-invite` (the host of `STF_URL` for `0.0.0.0`); the value of the previous setup is kept |
| `AGENT_HOSTS` | | legacy: the nodes without enrollment (`STF_PROVIDER_HOST` of their mcloud-agent) separated by commas, `stf-api` allows the screens of their devices, see [Nodes](#nodes); not asked by the setup, the value of the previous setup is kept, `nodes legacy-off` empties it |
| `ADB_RELAY` | `false` | `true`: `adb-relay` relays the remote debug ports of the Android devices of the enrolled nodes (the auto mode), see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay); the value of the previous setup is kept |
| `ADB_RELAY_PORTS` | | the auto mode relays the ports of this range only, `<first>-<last>` (e.g. `7400-7999`): the range opened in the firewall; empty: any port; the value of the previous setup is kept |
| `ADB_RELAY_SYNC_SECONDS` | `300` | the auto mode reads the devices of STF every these seconds: a new device is relayed within this time (at once after `./zebrunner.sh restart`); the value of the previous setup is kept |
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
| `STF_STORAGE_TOKEN` | generated | the token of the STF units for the storage routes; legacy: the same value as `STF_STORAGE_TOKEN` of the mcloud-agent of a node without enrollment, `nodes legacy-off` makes a new one |
| `STF_TOKEN` | | the access token of the STF user the grid reserves the devices with; an admin of STF for the [node commands](#nodes) and the auto mode of `adb-relay` |
| `NODE_REGISTRATION_TOKEN` | generated | legacy: the secret the Appium nodes of the nodes without enrollment register in the grid with, the same value as `NODE_REGISTRATION_TOKEN` of their mcloud-agent; `nodes legacy-off` makes a new one |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud |
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
| `STF_ZMQ_CURVE_CLIENT_KEY_<HOST>` | | legacy: the public key of one node without enrollment (`./zebrunner.sh curve-key` of mcloud-agent), one variable per node, `<HOST>` is a free label of letters, digits and `_` (e.g. `STF_ZMQ_CURVE_CLIENT_KEY_ANDROID_01`): the triproxies accept these keys and the ones of the enrolled nodes; an empty value is ignored, an invalid one stops STF with an error naming the variable; `nodes legacy-off` empties them |
| `STF_ZMQ_CURVE_CLIENT_KEYS` | | legacy: the public keys of the nodes without enrollment separated by commas, kept for compatibility: the triproxies accept them too |

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

The device hosts (the nodes, mcloud-agent) connect to ZeroMQ of STF (the triproxies), their Appium nodes register in the grid. Neither has an authentication of its own: anyone who reaches their ports reads the events of all the devices or sends commands to them, and a node registered in the grid gets the sessions of its device with their capabilities (the personal `zebrunner:STF_TOKEN` too). So `./zebrunner.sh setup` turns the authentication on:

- the triproxies accept only the clients with a known CURVE key ([ZeroMQ of STF](https://github.com/zebrunner/stf/blob/develop/ZEBRUNNER.md#zeromq)): the STF units, the active [enrolled nodes](#nodes) and the legacy keys of `STF_ZMQ_CURVE_CLIENT_KEY_<HOST>` (and `STF_ZMQ_CURVE_CLIENT_KEYS`), never the key of a revoked node; the traffic is encrypted. `./zebrunner.sh setup` makes the keys of the server (X25519, as `stf curve-keygen`) with openssl or, where it has no X25519, with `patch/curve_keygen.py`, the same as of mcloud-agent;
- RethinkDB has a password, `RETHINKDB_ENV_AUTHKEY`, its web console is off and its port is not published: only the STF units of the server use the database;
- the grid registers only the Appium nodes with the token of an enrolled node, verified by STF for the address of the node, or (legacy) with `NODE_REGISTRATION_TOKEN` of `variables.env` ([Node registration of mcloud-grid](https://github.com/zebrunner/mcloud-grid#node-registration)), and sends it with its requests to them: the Appium of a device answers the grid only, the devices are used through `/mcloud/wd/hub` and reserved in STF;
- the storage of STF accepts the uploads of the devices with the token of an enrolled node or (legacy) `STF_STORAGE_TOKEN`.

A node gets its key, its token and the settings of MCloud by its [enrollment](#nodes). The manual settings of the earlier releases still work for the nodes that are not enrolled yet, until `./zebrunner.sh nodes legacy-off` ([Migration from the manual settings](#migration-from-the-manual-settings)): the node makes its own key pair, `./zebrunner.sh curve-key` of mcloud-agent prints its public key, it goes to `variables.env` as one line per node, the suffix is a free label of the node (letters, digits and `_`), then `./zebrunner.sh restart`:

```bash
STF_ZMQ_CURVE_CLIENT_KEY_ANDROID_01=<the public key of the node, 64 hex characters>
```

An empty value is ignored, an invalid key stops the STF units with an error naming the variable. The removal of a line disconnects its node. `./zebrunner.sh setup` keeps these lines. `STF_ZMQ_CURVE_CLIENT_KEYS`, the public keys separated by commas, is kept for compatibility: the triproxies accept the keys of both. Such a node needs `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY`, `NODE_REGISTRATION_TOKEN` and `STF_STORAGE_TOKEN` of `variables.env` in its mcloud-agent and its address in `AGENT_HOSTS` of `.env` for the screens.

The nodes need mcloud-agent of the same MCloud release; the others cannot connect.

### Screens of the devices

The screen of a device is a WebSocket of its STF provider on the node, which the browser opens through `stf-proxy`: `/d/<address of the node>/<serial>/<port>/`, on a port 1024-65535. `stf-proxy` asks `stf-api` first (`auth_request` of `/api/v1/zebrunner/screen-auth` with the session cookie or the access token of the request and its URI in `X-Original-URI`, no other header of the user); `stf-api` allows it (`204`) only when:

- the user is signed in (`401` otherwise) and uses the device (or is an admin of STF);
- the device is bound to an active enrolled node whose registered address is `<address of the node>`, and `<port>` is the screen port of the device;
- or, legacy, the device is bound to no node, `<address of the node>` is in `AGENT_HOSTS` of `.env` (`stf-api` gets it) and is not the address of an enrolled node.

Anything else gets `403`. `stf-proxy` passes only the headers of the WebSocket to the node: never the session cookie, the `Authorization` header or the `X-Stf-*` headers of the user, the node is not trusted with them.

### Device hosts in a private network

The device hosts may be in a private network (LAN) with the MCloud server, only the server is public. The address of the invite of a node (`./zebrunner.sh node-invite <label> <address>`) is its LAN address (or a LAN host name), its `STF_PROVIDER_HOST`; a node without enrollment (legacy) sets it in its mcloud-agent and needs it in `AGENT_HOSTS` of `.env`:

- the screens: browser -> `wss://<public host>/d/<STF_PROVIDER_HOST>/...` -> `stf-proxy` -> the device host over the LAN;
- the tests: client -> `mcloud-grid` -> the Appium node of the device host over the LAN; the hub registers a node only when it reaches `http://<STF_PROVIDER_HOST>:<Appium port>`, otherwise it answers the registration with `500` and logs `Node <url> is not reachable from the hub`;
- ZeroMQ of STF, the storage and S3 are outbound connections of the device host.

The nodes reach the server at the host of the join string: `AGENTS_ADDRESS` of `.env` when it is set (e.g. the LAN address of the server), the public host name of `STF_URL` otherwise; resolve that name to the LAN address of the server on every node (e.g. `/etc/hosts`, the docker containers use it through the stub resolver of systemd-resolved) or set `AGENTS_ADDRESS`. A public address of a device host as `STF_PROVIDER_HOST` often fails inside the LAN (no NAT hairpin): neither the hub nor `stf-proxy` connects to it. Only the remote ADB of a user (`adb connect <STF_PROVIDER_HOST>:<port>`) needs a direct route from the user to the device host.

### Remote debug through the adb relay

STF shows the remote debug of an Android device as `adb connect <host>:<port>`: the host is `STF_PROVIDER_HOST` of mcloud-agent, the port is the remote debug port of the device on its device host, `connect_port` of the device in mcloud-agent or `min_port` + 1 by default (its `min_port` is its screen). A device host in a private network, where only the server of MCloud is public, works through the server (the screens through `stf-proxy`, the tests through the grid, ZeroMQ and the storage are connections of the device host to the server), but the users do not reach the ports of its devices. The optional `adb-relay` relays the remote debug ports through the server.

The auto mode, the recommended setup:

1. Set `ADB_RELAY=true` of `.env` and `ADB_RELAY_PORTS` to the range of the remote debug ports the server relays, the one opened in its firewall (e.g. `ADB_RELAY_PORTS=7400-7999`). The devices are the ones of the enrolled nodes.
2. Run `./zebrunner.sh restart`: it starts `adb-relay` and warns about an empty `STF_TOKEN` of `variables.env` and the invalid settings.
3. Set `REMOTE_CONNECT_HOST` of mcloud-agent of these device hosts to the public name of MCloud (the host of `STF_URL`) and deploy it again: STF shows `adb connect <REMOTE_CONNECT_HOST>:<port>` then (mcloud-agent passes it to [mcloud-device](https://github.com/zebrunner/mcloud-device)), `STF_PROVIDER_HOST` without it. `connect_port` of a device in mcloud-agent is optional: it sets the remote debug port, e.g. to keep the ports of the devices in `ADB_RELAY_PORTS`.
4. Open `ADB_RELAY_PORTS` in the firewall of the server for the users, see [Firewall](#firewall), and the remote debug ports of the devices of the device hosts for the server.

`adb-relay` reads the Android devices of the enrolled nodes from the STF API (`GET /api/v1/nodes/relay`: the devices bound to an active node) every `ADB_RELAY_SYNC_SECONDS` (`300`) and relays the remote debug port of every one of them (`connectPort` of the device in STF) to the same port of the registered address of its node, present or not (the node refuses the port of an absent device): the address the admin gave in the invite, never an address the node or the device reports. It skips an address of the server itself or of the link (loopback, link-local, multicast), a port out of `ADB_RELAY_PORTS` and a port of MCloud or of `ADB_RELAY_HOSTS`; the screen ports are never relayed. A port of two devices is relayed for neither of them, the log names both: change `connect_port` of one of the devices in mcloud-agent.

The devices of the nodes without enrollment (legacy) are not relayed by the auto mode: their address comes from the node itself, which the relay in the network of the host does not trust. Relay them with `ADB_RELAY_HOSTS` (below) until they are enrolled. As the absent devices stay relayed, the servers of nginx change only when a device is added to STF, removed from it or gets another port: then `adb-relay` reloads nginx, the open adb sessions go on. `docker logs adb-relay` lists the relayed devices and the skipped ones with the reason whenever they change.

Why the relay polls STF: STF is the single source of truth of the nodes and of their devices, mcloud-agent already registers every device with its ports there and the relay only reads them. The nodes need no channel and no secret to the relay, and after a restart of the relay, of STF or of a node the relay comes back to the devices of STF by itself. A new device is relayed within `ADB_RELAY_SYNC_SECONDS`, or at once after `./zebrunner.sh restart` (or `docker restart adb-relay`): the relay reads the devices when it starts.

The relay reads the API with `STF_TOKEN` of `variables.env`, the access token of the grid (its user sees the devices): `./zebrunner.sh setup`, `start` and `restart` copy only this token into `configuration/adb-relay/stf-token` (readable for its owner only, empty without the auto mode), the only secret of MCloud the relay on the network of the host gets, given to curl on its stdin; the relay reads it on every sync, so a new token needs `./zebrunner.sh start`, not a restart of the relay. The registry of the nodes needs an admin of STF. It reaches the API through `stf-proxy` on `127.0.0.1:STF_PORT` of the server with the scheme of `STF_URL` (`stf-proxy` has the certificate of the public name, it is not checked on the loopback address); when the API fails, the relay keeps its devices.

A fixed list instead of the auto mode, or in addition to it: `ADB_RELAY_HOSTS` of `.env`, the remote debug ports of the devices, `<host>:<port>` separated by commas, e.g. `ADB_RELAY_HOSTS=192.168.30.2:7404,192.168.30.2:7464,192.168.30.3:7704`; `./zebrunner.sh doctor` of mcloud-agent prints the entries of its host. The host is an IPv4 address or a host name of the device host in the network of the server, a host is in an entry for every device; the ports are 1024-65535, unique (the server relays a port to one device host) and not the ones of MCloud (`STF_PORT`, `4446`, `7160`, `7250`, `7260`, `7270`). `./zebrunner.sh restart` writes `configuration/adb-relay/relay-hosts.conf` from it (an invalid entry, a port of an earlier entry or of MCloud is reported and skipped) and starts `adb-relay`; `REMOTE_CONNECT_HOST` and the firewall as in the auto mode.

`adb-relay` is the nginx of `stf-proxy` (`TAG_NGINX`) in the network of the host (`network_mode: host`: a port per device, not published one by one) with `configuration/adb-relay/adb-relay.sh`, the sync of the auto mode: it listens on every relayed port on every address of the server and connects to the same port of the device host; an idle session ends after 24 hours. `./zebrunner.sh` starts it (the compose profile `adb-relay`) only when `ADB_RELAY=true` or `ADB_RELAY_HOSTS` has a valid entry, `stop`, `down`, `restart` and `shutdown` take it along also after they are cleared: run `./zebrunner.sh restart` after a change of the `ADB_RELAY*` settings (also in Zebrunner CE). `docker logs adb-relay` also shows every session: the client, the port, the device host, the bytes and the duration. On macOS the network of the host of Docker Desktop is the one of its VM: the ports need its host networking (Settings, Resources, Network).

The relay has no authentication of its own, it makes its ports public as they are. The remote debug port of a device listens only while a user of STF uses the device (the Remote debug of its dashboard starts it) and accepts an adb client with an adb key of that user only (STF, Settings, ADB keys): an unknown key makes STF ask that user to add it, add only your own keys.

An entry `<host>:<first>-<last>` of `ADB_RELAY_HOSTS` relays a whole range, e.g. `min_port`-`max_port` of all the devices of a device host. It is accepted, but `./zebrunner.sh` warns: the range also makes the screens of the devices public (their `min_port`), WebSockets without an authentication of their own that `stf-proxy` serves to the signed-in users only (see [Screens of the devices](#screens-of-the-devices)), the relay to anyone. Use a range only behind a firewall that opens it to the networks of the users (the office, a VPN); the auto mode relays no screen.

### Firewall

The ports of the host and who needs them; close the others:

| Port | Service | Clients |
| --- | --- | --- |
| `STF_PORT` | `stf-proxy` | the users, the tests, the nodes (the enrollment, the storage, the screens) |
| `7160`, `7250`, `7260`, `7270` (`AGENTS_ADDRESS`) | ZeroMQ of STF (`stf-triproxy-app`, `stf-triproxy-dev`) | the nodes |
| `4446` (`AGENTS_ADDRESS`) | `mcloud-grid` | the nodes (Appium registers to the grid); the tests use `/mcloud/wd/hub` of `STF_PORT` |
| `ADB_RELAY_PORTS`, the ports of `ADB_RELAY_HOSTS` | `adb-relay` (optional) | the users: `adb connect` of the remote debug of the devices of the device hosts in a private network, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay) |

`AGENTS_ADDRESS` publishes these ports on one address of the host, e.g. the one of the network of the device hosts; the join string of `./zebrunner.sh node-invite` gives the nodes this address (the host of `STF_URL` for `0.0.0.0`) for `STF_PORT`, the grid and ZeroMQ. A device host publishes the ports of its devices for the server (`stf-proxy` serves the screens to the users) and for the remote ADB of the users, see [mcloud-agent](https://github.com/zebrunner/mcloud-agent); `adb-relay` relays them to the users from a device host in a private network.

### Basic authentication of the grid

See [configuration/stf-proxy/htpasswd](configuration/stf-proxy/htpasswd/README.md).

### Files and secrets

`variables.env`, `backup/settings.env`, the key of the certificate (`configuration/stf-proxy/ssl/ssl.key`), the access token of the auto mode of `adb-relay` (`configuration/adb-relay/stf-token`), the archive of the database (`backup/rethinkdb.tar.gz`) and their backups hold the secrets of the deployment: `setup`, `start`, `backup` and `restore` keep them readable for their owner only (`600`). Run `zebrunner.sh` as the user of the deployment; a `sudo ./zebrunner.sh` gives the files it writes back to the owner of the folder.

## Nodes

A node is a device host of [mcloud-agent](https://github.com/zebrunner/mcloud-agent). Every node is enrolled: the admin invites it by its label and its address, the node joins with the invite and gets an identity of its own, its CURVE key for ZeroMQ and its token for the grid and the storage, which STF keeps in its registry of the nodes. The devices of a node are bound to it, the screens and the remote debug of them go to its registered address only, and a node is revoked alone. The manual keys and tokens of the earlier releases are legacy, see [Migration from the manual settings](#migration-from-the-manual-settings).

### Enrollment

The server needs https with the certificate of the host ([https](#https)), the services running, `STF_TOKEN` of `variables.env` of an admin of STF and the STF of this MCloud release (`TAG_STF`).

1. On the server: `./zebrunner.sh node-invite <label> <address> [<minutes>]`, e.g. `./zebrunner.sh node-invite lab-1 192.168.30.2`:
   - the label is the name of the node, unique, 1-40 lower case letters, digits and `-`;
   - the address is the one the server connects to (the screens, Appium), the `STF_PROVIDER_HOST` of the node: an IPv4 address or a host name without the protocol and the port, not a loopback, link-local or multicast one, unique among the nodes;
   - the invite is valid 60 minutes, `<minutes>` sets 1-1440, and enrolls once.
2. It prints the join string once, a secret: copy it to the node over a trusted channel.
3. On the node: `./zebrunner.sh join` of mcloud-agent reads the join string from stdin or a hidden prompt (never from its arguments), checks the certificate of `stf-proxy` by the pin, enrolls the key of the node with the invite and writes the settings of MCloud into mcloud-agent; then deploy the node as mcloud-agent describes.
4. `./zebrunner.sh nodes` shows the node `active`, with the time it was last seen by the grid.

A new invite of an enrolled label enrolls the node again: its new key and token replace the old ones at once, the regular way to rotate them. A new invite of a label also cancels the earlier invites of that label that are not used yet.

### The join string

```text
mcloud-join://<host>:<port>?label=<label>&grid=<grid host>:<grid port>&pin=<pin>&token=<invite>
```

| Part | Value |
| --- | --- |
| `<host>` | the host the node reaches the server at: `AGENTS_ADDRESS` of `.env`, the host of `STF_URL` when it is `0.0.0.0` (every address) |
| `<port>` | `STF_PORT`, the port of `stf-proxy`: the enrollment, the storage, the API |
| `label` | the label of the node |
| `grid` | `<host>:4446`, the published port of the grid (`docker-compose.yml`) |
| `pin` | base64 of the SHA-256 of the public key (DER SubjectPublicKeyInfo) of `configuration/stf-proxy/ssl/ssl.crt`, as `curl --pinnedpubkey 'sha256//<pin>'` takes it, with `+`, `/` and `=` percent-encoded (`%2B`, `%2F`, `%3D`); `node-invite` also prints it as it is |
| `token` | the invite, `mci1.<secret>` |

The parameters are in this order and URL-safe. The node takes the ports of ZeroMQ from the answer of the enrollment and their host from the join string: the triproxies publish `7160`, `7250`, `7260` and `7270` on `AGENTS_ADDRESS`, the same host, see [Firewall](#firewall). A new certificate of `stf-proxy` changes the pin of the next invites.

### Commands

| Command | What it does |
| --- | --- |
| `./zebrunner.sh node-invite <label> <address> [<minutes>]` | an invite of a node, the join string is printed once |
| `./zebrunner.sh nodes`, `nodes list` | the nodes of the registry: the label, the address, `active` or `revoked`, the time the grid last saw it, the time of its enrollment, the first characters of its key |
| `./zebrunner.sh nodes revoke <label>` | revokes a node and restarts `stf-triproxy-app` and `stf-triproxy-dev`, which ends its open ZeroMQ sessions (the other nodes reconnect at once) |
| `./zebrunner.sh nodes delete <label>` | removes a revoked node from the registry: its label and its address are free again |
| `./zebrunner.sh nodes legacy-off` | the end of the manual keys and tokens, see [Migration from the manual settings](#migration-from-the-manual-settings) |

They call the STF API through `stf-proxy` on `127.0.0.1:STF_PORT` of the server (with the scheme of `STF_URL`, the certificate is not checked on the loopback address) with `STF_TOKEN` of `variables.env`, which goes to curl on its stdin and is never printed. The API answers an error without details, `docker logs stf-api` has them.

### Revocation

Revoke a node that is lost or given away, whose host or settings may be read by others, or that is not needed any more: `./zebrunner.sh nodes revoke <label>`. At once the triproxies refuse its key (a revoked key is refused even when it is one of the legacy keys), the storage and STF its token, its devices lose their binding (no screen, no remote debug relay); the grid drops its Appium nodes on the next check of their token (every 60 seconds). A new invite of the label enrolls it again with a new key and token; `nodes delete` removes it.

### Migration from the manual settings

The earlier releases authenticated the device hosts with shared settings: the keys of `STF_ZMQ_CURVE_CLIENT_KEY_<HOST>` and `STF_ZMQ_CURVE_CLIENT_KEYS`, `NODE_REGISTRATION_TOKEN` and `STF_STORAGE_TOKEN` of `variables.env` in every mcloud-agent, the device hosts of `AGENT_HOSTS` of `.env` for the screens. They keep working next to the enrolled nodes until `nodes legacy-off`:

1. Update the server and the nodes ([Upgrade](#upgrade)). `stf-proxy` has no list of the device hosts any more: `AGENT_HOSTS` goes to `stf-api`, which allows the screens of the devices of a legacy node at these hosts only while they are bound to no node and the host is not the address of an enrolled node; `./zebrunner.sh start` removes `configuration/stf-proxy/agent-hosts.conf` of the earlier releases and the setup does not ask `AGENT_HOSTS` any more (it keeps the value).
2. Enroll every node with its current `STF_PROVIDER_HOST` as the address ([Enrollment](#enrollment)); its line of `STF_ZMQ_CURVE_CLIENT_KEY_<HOST>`, its entry of `AGENT_HOSTS` and its ports in `ADB_RELAY_HOSTS` are not needed any more (the auto mode of `adb-relay` relays the enrolled nodes).
3. `./zebrunner.sh nodes` lists every node `active`.
4. `./zebrunner.sh nodes legacy-off`: it warns that every node that is not enrolled stops working, shows the nodes and asks (no by default); then it empties `STF_ZMQ_CURVE_CLIENT_KEYS` and every `STF_ZMQ_CURVE_CLIENT_KEY_<HOST>` of `variables.env` and `AGENT_HOSTS` of `.env`, makes new random `NODE_REGISTRATION_TOKEN` and `STF_STORAGE_TOKEN` (not shown, the STF units use the new storage token) and restarts the services.

### Security

What the enrollment gives:

- every node has its own key and token (`mcn1.<label>.<secret>`, 256 random bits): a node is revoked alone, the others go on; STF keeps the SHA-256 of the tokens and the invites only;
- an invite has 256 random bits, is used once (also by two parallel enrollments), expires (60 minutes by default) and is bound to the label and the address the admin chose; the enrollment is limited in `stf-proxy` to 6 a minute per client address (a burst of 3, then `429`);
- the node trusts the server by the pin of the certificate of `stf-proxy`, a self-signed certificate is fine; the join string is never an argument of a command (the process list), the server prints it once;
- the address of a node is the one of the admin, never one the node reports: the grid takes a node token only for an Appium node at that address, a device is bound to the node only with a proof of the token of the node (an HMAC) and at that address, the screens and the remote debug relay go to the registered address only, so a node cannot point the server at another host;
- the screens are served to the user of the device only, and `stf-proxy` never passes the session cookie, the access token or the `X-Stf-*` headers of the user to the node;
- `STF_TOKEN` stays on the server: the commands give it to curl on its stdin, `adb-relay` gets it alone.

The risks that stay:

- the join string is a secret until it is used or expires: whoever uses it first enrolls as that node (still bound to its address). Send it over a trusted channel, keep the validity short and revoke a node enrolled by surprise (`nodes` shows the key and the time it was last seen);
- whoever is root on a node, or in its docker group, has its key and token and acts as that node (its devices, the sessions of its devices, its uploads) until it is revoked, not as another node;
- the server reaches the screens and Appium of a node over plain HTTP and WebSocket at its address; only ZeroMQ is encrypted. Someone who takes the address of a node in its network (ARP or DNS spoofing) sees that traffic: keep the nodes in a trusted network or a VPN;
- the legacy settings keep their weaknesses (shared secrets, the device hosts of `AGENT_HOSTS`) until `nodes legacy-off`;
- the limit of the enrollment is per client address: behind another proxy all the clients share one, and many addresses only slow down; the 256 bits of an invite keep the guessing hopeless anyway;
- a revocation ends the open ZeroMQ sessions by a restart of the triproxies (all the nodes reconnect), the grid drops a revoked node within 60 seconds and the storage may accept its token for up to 60 seconds (its cache);
- `STF_TOKEN` of `variables.env` is a token of an admin of STF: `variables.env` is readable for its owner only, see [Files and secrets](#files-and-secrets).

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
| `POST /api/v1/nodes/enroll` | the enrollment of a node with its invite, limited to 6 a minute per address (a burst of 3, then `429`), see [Nodes](#nodes) |
| `/mcloud/wd/hub` | the Selenium/Appium hub URL |
| `/mcloud/grid/console` | the grid console with the devices |
| `/mcloud/grid/admin/DevicesServlet` | the devices of the grid as JSON: their status and sessions |
| `/mcloud/grid/admin/AllSessionsServlet` | the active sessions as JSON |
| `/mcloud/grid/admin/MetricsServlet` | the Prometheus metrics of the grid |
| `POST /mcloud/grid/admin/TerminateSessionServlet` | terminates the session of a device, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#terminating-a-session) |

## Upgrade

An MCloud release works with mcloud-agent of the same release only (the images of the device hosts, the authentication of the device hosts): update the server and all the device hosts together.

1. Update the repository: `git pull`.
2. Run `./zebrunner.sh setup`: it keeps the settings of the previous setup and generates the missing ones.
3. Update mcloud-agent of every device host to the same release, see its README.
4. Restart the services: `./zebrunner.sh restart`; `stf-migrate` updates the tables of the database.
5. Enroll the nodes and turn the manual settings off: [Migration from the manual settings](#migration-from-the-manual-settings).

## Troubleshooting

`docker logs <service>` shows the log of a service, `docker ps` the unhealthy ones (see [Services](#services)).

| Symptom | Cause and fix |
| --- | --- |
| `./zebrunner.sh start` fails to pull: `denied: Your authorization token has expired` or `403 Forbidden` from `public.ecr.aws` | an expired login to public.ecr.aws in `~/.docker/config.json` of the user: the images are public, `docker logout public.ecr.aws` (or log in again: `aws ecr-public get-login-password --region us-east-1 \| docker login --username AWS --password-stdin public.ecr.aws`) |
| the pull fails with `manifest unknown` | the tag of `TAG_*` of `.env` is not published: the tags of `.env.original` of the current MCloud |
| the devices are in STF, not in `/mcloud/grid/console`; `mcloud-grid` logs `Could not get the device '<udid>' from STF (HTTP 401), the node is not registered.` | `STF_TOKEN` of `variables.env` is empty or not an access token of STF: generate one (STF, Settings, Keys), set it and `./zebrunner.sh restart` (`start` warns while it is empty) |
| `mcloud-grid` logs `Node <url> has no or another NODE_REGISTRATION_TOKEN than the hub, so it is not registered.` | an enrolled node: its token is revoked or of an earlier enrollment, or the host of its URL is not its registered address (`./zebrunner.sh nodes`); enroll it again (`node-invite`, `join`). A legacy node: `NODE_REGISTRATION_TOKEN` of the node differs from `variables.env` (or `nodes legacy-off` made a new one): enroll it |
| the nodes of a device host are not in the grid: Appium logs a registration answered with `500`, `mcloud-grid` logs `Node <url> is not reachable from the hub` | the hub does not reach `http://<STF_PROVIDER_HOST>:<Appium port>` of the device host: `STF_PROVIDER_HOST` of mcloud-agent must be reachable from the MCloud server (and its firewall open); in a private network use the LAN address of the device host and add it to `AGENT_HOSTS` of `.env`, see [Device hosts in a private network](#device-hosts-in-a-private-network) |
| the node is up, its devices are not in STF (the `stf` container of an Android device restarts after `Providing all 0 of 1 device(s)`); `stf-triproxy-app` or `stf-triproxy-dev` logs `Refused the ZeroMQ client <address> with the unknown key "<key>"` | the key of the node is not of an active enrolled node (`./zebrunner.sh nodes`: revoked, or a key of an earlier enrollment): enroll it again; a legacy node: its key is not in `STF_ZMQ_CURVE_CLIENT_KEY_<HOST>` (or `STF_ZMQ_CURVE_CLIENT_KEYS`) of the running services, or `nodes legacy-off` emptied them; a node with another `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY` than `variables.env` is not let in either, see [Authentication of the device hosts](#authentication-of-the-device-hosts) |
| the screen of a device stays gray, `/d/<node>/...` answers `403` | `stf-api` refuses it: the user does not use the device, the node is revoked or the device is not bound to it (its `STF_NODE_TOKEN`, its `STF_PROVIDER_HOST` is not the registered address), or a legacy node is not in `AGENT_HOSTS` of `.env` (or its address is the one of an enrolled node), see [Screens of the devices](#screens-of-the-devices) (`401`: the user is not signed in); `500`: the STF of `TAG_STF` has no `/api/v1/zebrunner/screen-auth` |
| the screenshots or the app installs of the devices fail with `401` / `403` | the node is revoked or its token is of an earlier enrollment; a legacy node: its `STF_STORAGE_TOKEN` differs from `variables.env` (or `nodes legacy-off` made a new one) |
| `./zebrunner.sh node-invite` or `nodes` fails: `stf-proxy does not answer`, `not a valid access token`, `not of an admin`, `no registry of the nodes` | the commands call the STF API through `stf-proxy` on `127.0.0.1:STF_PORT` of the server with `STF_TOKEN` of `variables.env`: the services run (`./zebrunner.sh start`), `STF_TOKEN` is an access token of an admin of STF, `TAG_STF` is the STF of this MCloud release; the API answers the details in `docker logs stf-api` only |
| `./zebrunner.sh node-invite` fails with `The enrollment needs https of stf-proxy` | the node trusts the certificate of `stf-proxy` by its pin only: set MCloud up with https and its certificate, see [https](#https) |
| `./zebrunner.sh join` of the node fails with `429` | the enrollment is limited to 6 a minute per address: wait a minute; behind another proxy (e.g. the nginx of Zebrunner CE) every node has its address, the join string points to `stf-proxy` itself (`STF_PORT`) |
| `configuration/adb-relay/relay-hosts.conf is not writable` (or `stf-token`) | the file was written by root (`sudo ./zebrunner.sh ...`): remove it (`rm -f configuration/adb-relay/<file>`) and `./zebrunner.sh restart`; `adb-relay` keeps the servers and the token it has until then |
| `adb connect` of STF to a device of a device host in a private network times out or fails | `REMOTE_CONNECT_HOST` of mcloud-agent is not the public name of MCloud, the relay skips the port or the firewall of the server closes it, see [Remote debug through the adb relay](#remote-debug-through-the-adb-relay): `docker logs adb-relay` lists the relayed devices and the skipped ones with the reason (e.g. a port out of `ADB_RELAY_PORTS`, a port of two devices of STF; a legacy node is not relayed by the auto mode, its ports go to `ADB_RELAY_HOSTS`), a new device is relayed within `ADB_RELAY_SYNC_SECONDS`, the ports of `ADB_RELAY_HOSTS` are in `configuration/adb-relay/relay-hosts.conf`; it also shows the sessions and why a device host refused one |
| `docker logs adb-relay` shows `The STF API ... failed` or `answered without devices` | the auto mode does not read the devices: `401` is an invalid `STF_TOKEN` of `variables.env` (a new access token of STF, Settings, Keys, then `./zebrunner.sh start` writes it into `configuration/adb-relay/stf-token`), `403` is a token of a user that is not an admin, `404` an STF of `TAG_STF` without the registry of the nodes; a failed connection is `stf-proxy` not running or not with the scheme of `STF_URL` (http or https); the relay keeps its devices until the next successful sync |
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
| `make test` | `tests/zebrunner_test.sh` and `tests/utility_test.sh`: the commands of `zebrunner.sh` on a copy of the repository with `docker` and `curl` stubs (the node commands with answers of the STF API, the configuration of `stf-proxy`); `tests/adb_relay_test.sh`: the sync of `configuration/adb-relay/adb-relay.sh` with answers of the STF API and stubs | bash, openssl, Python 3 |
| `make docker` | `tests/compose_test.sh`: the setup, the start and the endpoints of the services, `adb-relay` with a stand-in device host, then their shutdown; `tests/adb_relay_docker_test.sh`: the auto mode of `adb-relay` with a fake STF API and a stand-in node (the sessions, the reload, the errors); `tests/stf_proxy_docker_test.sh`: the configuration of `stf-proxy` with a fake `stf-api` and a fake node (the decision about the screens, the headers each side gets, the limit of the enrollment); `TAG_STF=<tag> TAG_SELENIUM_HUB=<tag> make docker` checks other images | Docker, no other MCloud on the machine |

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
