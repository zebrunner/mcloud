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
| Operating System | Ubuntu 24.04, Linux CentOS 7+, Amazon Linux 2, macOS |
| CPU | 4+ Cores |
| Memory | 16 Gb RAM |
| Free space | SSD 32Gb+ of free space |

- Docker v27+ with the Docker compose plugin
- git 2.20.0+

## Run

1. Clone [mcloud](https://github.com/zebrunner/mcloud) and set it up, provide valid protocol, hostname and port:

   ```bash
   git clone https://github.com/zebrunner/mcloud.git && cd mcloud && ./zebrunner.sh setup
   ```

2. Start the services: the setup offers it, otherwise `./zebrunner.sh start`.
3. Open `http://hostname:80/stf`.
4. Log in using any name/email values as `auth-mock` is configured by default.
5. Go to Settings, Keys and generate a new Access Token.
6. Paste the generated token into `variables.env` as `STF_TOKEN`.
7. Restart the services: `./zebrunner.sh restart`.
8. Set up the servers with Android and iOS devices according to [mcloud-agent](https://github.com/zebrunner/mcloud-agent), the same on Linux and macOS ([mcloud-ios](https://github.com/zebrunner/mcloud-ios) is deprecated). Set `STF_STORAGE_TOKEN` of mcloud-agent to the `STF_STORAGE_TOKEN` of `variables.env`: the STF storage accepts the uploads of the devices with this token only.
9. Use `http://hostname:80/mcloud/grid/console` to see the connected devices and `http://hostname:80/mcloud/wd/hub` as the Selenium/Appium hub URL for test automation.

Follow the installation and configuration guide in [Zebrunner CE](https://zebrunner.github.io/community-edition) to reuse MCloud components effectively for Test Automation.

The commands of `./zebrunner.sh`:

| Command | What it does |
| --- | --- |
| `setup` | writes `.env`, `variables.env` and `configuration/stf-proxy/nginx.conf` from their `*.original` files, then offers to start the services; the values of the previous setup are kept |
| `start` | starts the services, the first start runs `setup` |
| `stop` | stops the services, the containers are kept |
| `restart` | `down` and `start` |
| `down` | stops and removes the containers, the data is kept |
| `shutdown` | removes the containers, the data and the settings |
| `backup`, `restore` | the settings to `*.bak` and the database to `backup/rethinkdb.tar.gz`, and back |
| `version` | the version of MCloud, the tag of the STF image |

## Configuration

`./zebrunner.sh setup` writes the settings from the `*.original` files, `./zebrunner.sh restart` applies their changes. The next setup writes `.env` again and keeps the values of the variables of `variables.env.original` in `variables.env` (but `STF_URL` and the `ZEBRUNNER_*` URLs, which come from the protocol, host and port); the other variables added to `variables.env` are added again after it.

`.env`, the settings of `docker-compose.yml`:

| Variable | Default | Description |
| --- | --- | --- |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud: the protocol, host and port of the setup |
| `STF_PORT` | `8082` | the port of `stf-proxy` on the host |
| `TAG_NGINX` | `1.25.3` | the tag of `nginx` |
| `TAG_SELENIUM_HUB` | `develop` | the tag of `public.ecr.aws/zebrunner/mcloud-grid` |
| `TAG_RETHINKDB` | `2.4.2` | the tag of `rethinkdb` |
| `TAG_STF` | `develop` | the tag of `public.ecr.aws/zebrunner/stf` |
| `AUTH_SYSTEM` | `auth-mock` | the sign-in unit of STF, `auth-zebrunner` in Zebrunner CE |
| `AUTH_URL` | `auth/mock/` | the path of the sign-in, `auth/zebrunner/` in Zebrunner CE |

`variables.env`, the settings of the STF units and of the grid:

| Variable | Default | Description |
| --- | --- | --- |
| `SECRET` | generated | the secret of the sessions and the access tokens of STF; a new deployment gets a random one, a change of it ends the sessions and invalidates the access tokens (`STF_TOKEN` too) |
| `STF_STORAGE_TOKEN` | generated | the token of the STF units for the storage routes, the same value as `STF_STORAGE_TOKEN` of mcloud-agent |
| `STF_TOKEN` | | the access token of the STF user the grid reserves the devices with |
| `STF_URL` | `http://localhost:8082` | the public URL of MCloud |
| `STF_ROOT_GROUP_NAME` | `MCloud` | the root group of STF |
| `STF_ADMIN_NAME`, `STF_ADMIN_EMAIL` | `admin`, `admin@zebrunner.com` | the administrator of STF, the owner of the root group |
| `ZEBRUNNER_LOGIN_URL`, `ZEBRUNNER_USERINFO_URL` | | the endpoints of Zebrunner IAM for `auth-zebrunner`, set by the setup of Zebrunner CE |
| `RETHINKDB_PORT_28015_TCP` | `tcp://rethinkdb:28015` | the database of STF |
| `AUTHKEY` | | not used by the current images |

More settings of STF (e.g. `STF_SESSION_TTL_SECONDS`, the lifetime of a session, or `STF_STORAGE_TEMP_DOWNLOAD_ALLOW`, the private networks the apps may be installed from by URL) are described in [ZEBRUNNER.md of STF](https://github.com/zebrunner/stf/blob/develop/ZEBRUNNER.md#configuration). The settings of the grid (e.g. `NODE_ALLOWED_NETWORKS`, `MAX_NEW_COMMAND_TIMEOUT`, `MCLOUD_LOG_LEVEL`) are described in [mcloud-grid](https://github.com/zebrunner/mcloud-grid#configuration), they go to `environment` of `mcloud-grid` in `docker-compose.yml`.

### https

`./zebrunner.sh setup` with the `https` protocol turns on the ssl of `stf-proxy` with a self-signed certificate; put your certificate and key into `configuration/stf-proxy/ssl/ssl.crt` and `configuration/stf-proxy/ssl/ssl.key` instead. `stf-proxy` passes the scheme of the client to STF (`X-Forwarded-Proto`, the one of a proxy in front of it when there is one), so the session cookie is `Secure` behind https. The ssl settings allow TLS 1.2 and 1.3 only.

### Security headers

`stf-proxy` adds `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` and `Content-Security-Policy: frame-ancestors 'self'` to every response and removes `X-Powered-By`: MCloud is not embedded into the pages of other sites. A site that frames MCloud (e.g. another host of Zebrunner) needs `frame-ancestors 'self' https://<host>` instead and no `X-Frame-Options` in `configuration/stf-proxy/nginx.conf`.

### Basic authentication of the grid

See [configuration/stf-proxy/htpasswd](configuration/stf-proxy/htpasswd/README.md).

## Services

All the services are in the external docker network `infra`, which `./zebrunner.sh start` creates.

| Service | Image | What it does |
| --- | --- | --- |
| `stf-proxy` | `nginx` | the entry point on `STF_PORT`: STF, the grid under `/mcloud`, the static files of the grid console |
| `mcloud-grid` | `public.ecr.aws/zebrunner/mcloud-grid` | the Selenium/Appium hub of the devices, also on the port `4446` of the host |
| `rethinkdb` | `rethinkdb` | the database of STF, the volume `stf-db-volume` |
| `stf-migrate` | `public.ecr.aws/zebrunner/stf` | creates and updates the tables of the database, the other STF units start after it |
| `stf-app`, `stf-auth`, `stf-api`, `stf-websocket` | `public.ecr.aws/zebrunner/stf` | the UI, the sign-in, the REST API and the websocket of STF |
| `stf-processor001`, `stf-reaper`, `stf-api-groups-engine` | `public.ecr.aws/zebrunner/stf` | the device events, the heartbeats and the groups of STF |
| `stf-triproxy-app`, `stf-triproxy-dev` | `public.ecr.aws/zebrunner/stf` | the message brokers of the STF units and of the devices, the ports `7150`-`7170` and `7250`-`7270` of the host |
| `stf-storage-temp`, `stf-storage-plugin-apk`, `stf-storage-plugin-image` | `public.ecr.aws/zebrunner/stf` | the storage of the apps and screenshots, the volume `stf-temp-volume`; protected by `STF_STORAGE_TOKEN` |

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

From the images `stf:3.0` and `mcloud-grid:2.6`:

1. Update the repository: `git pull`.
2. Run `./zebrunner.sh setup`: it keeps the settings of `variables.env` and generates `STF_STORAGE_TOKEN`.
3. Set the same `STF_STORAGE_TOKEN` in mcloud-agent and update it with its mcloud-device image to the versions of the new STF, then restart the devices.
4. Restart the services: `./zebrunner.sh restart`. `stf-migrate` creates the table of the sessions, the users sign in once more.

The setup warns when `SECRET` is still the default `password`: replace it in `variables.env` with a random value, then generate the access tokens again (`STF_TOKEN` too), as the old ones are signed with the old secret. The grid logs JSON lines now, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#logs).

## Components

- [mcloud-agent](https://github.com/zebrunner/mcloud-agent) - Device Farm agent for connecting Android and iOS devices including phones, tablets, and TVs over USB or Wi-Fi, Android emulators and iOS / tvOS simulators (macOS) via Linux or macOS.
- [mcloud-device](https://github.com/zebrunner/mcloud-device) - Dockerized STF provider image for Android and iOS devices.
- [mcloud-grid](https://github.com/zebrunner/mcloud-grid) - Enhanced Selenium Grid for automating physical devices and emulators/simulators via Appium.
- [stf](https://github.com/zebrunner/stf) - the STF of MCloud with iOS devices and the Zebrunner sign-in.
- [appium](https://github.com/zebrunner/appium) - Enhanced Appium image with low-level video recording and local storage for ipa/apk artifacts.
- [mcloud-redroid](https://github.com/zebrunner/mcloud-redroid) - GPU accelerated Android In Cloud solution.

## Development

| Target | What it checks | Needs |
| --- | --- | --- |
| `make check` | everything below, as CI runs it | |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, pymarkdown, shellcheck, shfmt, the text files, `docker compose config` with the `*.original` settings | Python 3; on macOS `brew install hadolint` |
| `make test` | `tests/zebrunner_test.sh` and `tests/utility_test.sh`: the commands of `zebrunner.sh` on a copy of the repository with a `docker` stub | bash |
| `make docker` | `tests/compose_test.sh`: the setup, the start and the endpoints of the services, then their shutdown; `TAG_STF=<tag> TAG_SELENIUM_HUB=<tag> make docker` checks other images | Docker, no other MCloud on the machine |

The tests write JUnit XML into `$JUNIT_DIR` when it is set. CI (`.github/workflows/ci.yml`) runs the jobs `lint`, `tests` (Linux and macOS) and `docker` on the pushes and pull requests.

The conventions of the style, the formatting and the tooling of this repository are in [CONVENTIONS.md](CONVENTIONS.md), the same in all the MCloud repositories. The rules of this repository:

- `docker-compose.yml` takes the image tags (`TAG_*`) and the ports from `.env`, the settings of the services from `variables.env`; `./zebrunner.sh setup` writes both from `.env.original` and `variables.env.original`, which keep the defaults. `make lint` checks `docker compose config` with the `*.original` files.
- Every image is pinned by its `TAG_*` in `.env.original` (checked by `make lint`).
- `zebrunner.sh` and `patch/*.sh` are [host scripts](CONVENTIONS.md#host-scripts): the interface of Zebrunner CE (`ZBR_INSTALLER`, the `ZBR_*` settings, `SHUTDOWN_CONFIRMED`, `.disabled`) and the commands stay compatible.
- The static files of the Selenium grid console (`configuration/stf-proxy/grid/`) are kept byte for byte: `generated` of `tests/lint_project.sh` and unset formatting in `.editorconfig`.
- A test of the services goes to `tests/compose_test.sh` (`DOCKER_TESTS`), a test of the commands of `zebrunner.sh` without docker to `tests/zebrunner_test.sh`.

## Support

- [Zebrunner PRO](https://zebrunner.com)
- [Zebrunner CE](https://zebrunner.github.io/community-edition)
- [Zebrunner Reporting](https://zebrunner.com/documentation)
- [Carina Guide](http://zebrunner.github.io/carina)
- [Demo Project](https://github.com/zebrunner/carina-demo)
- [Telegram Channel](https://t.me/zebrunner)

## License

[Apache License 2.0](LICENSE)
