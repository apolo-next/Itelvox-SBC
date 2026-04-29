# Itelvox-SBC

> Fork de [dSIPRouter](https://github.com/dOpensource/dsiprouter) customizado para desplegar la variante SBC de Itelvox sobre Kamailio + RTPEngine + dSIPRouter.

Este repositorio extiende dSIPRouter con:

- **Local API blueprint** (`gui/modules/local_api/`) — endpoints REST autenticados por token (`Bearer DSIP_API_TOKEN`) o sesión activa de la GUI, que reusan los modelos del core sin exponer el token al cliente.
- **Caller ID Mask Groups** (`gui/modules/api/calleridmasks/`, `gui/templates/caller_id_management.html`, `kamailio/defaults/dsip_caller_id_masks.sql`) — gestión de máscaras de Caller ID con UI dedicada.
- **Endpoint prefix gating** — schemas `dsip_endpoint_allowed_prefixes` y `dsip_endpoint_outbound_prefix` con sus htables y rutas en `kamailio.cfg`.
- **Flags `-iip` / `-eip`** en `dsiprouter.sh` para configurar IP interna/externa.
- **RTPEngine kernel-fwd fix** — uso de `dlg_var(dst_media_tp)` en `rtpengine/configs/rtpengine.conf`.
- **Performance tuning SBC** — `children=8`, SHM=2048, RTPEngine ports 30000-60000 con num-threads=16, `/etc/sysctl.d/90-dsiprouter.conf`, drop-ins systemd con `LimitNOFILE=1048576`.
- **Lab opcional** auto-contenido (`sbc-lab-setup.sh`) con topología 172.17.100/24.

## Scripts del fork

Los tres scripts en la raíz del repo se ejecutan en cadena sobre la instalación upstream:

| Archivo | Rol |
|---|---|
| `local_api_patch.sh` | Aplica los parches a nivel de fuente sobre el árbol de dSIPRouter. Idempotente vía marcadores `LOCAL_API_PATCH:*`. |
| `sbc-install.sh` | Instalador SBC top-level. Llama a `local_api_patch.sh` y añade tuning de rendimiento, sysctl, drop-ins systemd y el esquema `caller_id_masks`. Usa `verify_source_features` para fallar rápido si faltan features esperadas en el árbol fuente. |
| `sbc-lab-setup.sh` | Opcional. Despliega `/opt/test-lab/` (embebido como tar+base64). Configura alias de IP vía systemd oneshot. Variables `LAB_*` para customizar la topología. |

## Instalación (servidor nuevo)

```bash
git clone https://github.com/apolo-next/Itelvox-SBC.git /opt/dsiprouter
cd /opt/dsiprouter
./dsiprouter.sh install -iip <IP_INTERNA> -eip <IP_EXTERNA>
./sbc-install.sh
# Opcional:
./sbc-lab-setup.sh
```

## Sincronizar con upstream

El remote `upstream` apunta a `dOpensource/dsiprouter`. Para integrar cambios upstream en el fork:

```bash
git remote add upstream https://github.com/dOpensource/dsiprouter.git  # solo si no está
git fetch upstream
git merge upstream/master   # o rebase, según preferencia
git push origin master
```

Después de un merge, re-ejecutar `local_api_patch.sh` y `sbc-install.sh` en los servidores. Ambos son idempotentes (marcadores `LOCAL_API_PATCH:*`, `# SBC_INSTALL:*_v1`).

## Idempotencia

| Marcador | Dónde |
|---|---|
| `LOCAL_API_PATCH:*` | Archivos parcheados |
| `# SBC_INSTALL:*_v1` | Drop-ins de systemd / sysctl |
| `# SBC_LAB:*_v1` | Archivos de alias de IP del lab |
| `.sbc_lab_extracted` | Touch-file que marca extracción del lab |

El DDL de `caller_id_masks` es no-destructivo por defecto (se omite si `dsip_caller_id_mask_groups` ya existe). Forzar recreación: `FORCE_CALLER_ID_SCHEMA=1`.

## Caja de referencia

`sbc01.itelvox.com` — Debian 12, 172.17.100.10 privada, 45.71.33.106 pública, interfaces `ens192` / `ens224`.

---

# dSIPRouter Platform (upstream)


[<p align="center"><img src="docs/dsiprouter_300px.png" alt="dSIPRouter Logo" width="300"/></p>](https://dsiprouter.org)


## What is dSIPRouter?

dSIPRouter allows you to quickly turn [Kamailio](https://www.kamailio.org/) into an easy to use SIP Service Provider platform, which enables three basic use cases:

- **SIP Trunking services:**
Provide services to customers that have an on-premise PBX such as FreePBX, FusionPBX, Avaya, etc.
We have support for IP and credential based authentication.

- **Hosted PBX services:**
Proxy SIP Endpoint requests to a multi-tenant PBX such as FusionPBX or single-tenant such as FreePBX.
We have an integration with FusionPBX that make this really easy and scalable!

- **Microsoft Teams Direct Routing (Core Subscription Required):**
We can provide SBC functionality that allows dSIPRouter to interconnect your existing voice infrastructure or VoIP carrier to your Microsoft Teams environment.

- **WebRTC Proxy (Core Subscription Required):**
We can provide functionality that allows dSIPRouter to register WebRTC clients to PBX's that has extensions being exposed as just UDP and TCP.  Hence, becoming a WebRTC Proxy.

The dSIPRouter UI allows you to manage the platform.  We also make it easy to intergrate dSIPRouter into your existing workflow by using our [API](https://www.postman.com/dopensource/workspace/dsiprouter/overview)

**Follow us at [#dsiprouter](https://twitter.com/dsiprouter) on Twitter to get the latest updates on dSIPRouter**

### Project Web Site

Check out our official website [dsiprouter.org](http://dsiprouter.org)

### Demo System

Try out our demo system [demo.dsiprouter.net](https://demo.dsiprouter.net:5000/)

Demo system GUI Credentials:
- username: `admin`
- password: `ZmIwMTdmY2I5NjE4`

Demo system API Credentials:

You can test out the API using the demo system.  We have defined a [Postman](https://www.postman.com/dopensource/workspace/dsiprouter/overview) collection that will make the process easier.  The API token is below:

- bearer token: `9lyrny3HOtwgjR6JIMwRaMej9LijIS835zhVbD8ywHDzXT07Xm6vem1sgfvWkFz3`

### Documentation

You can find our documentation online: [dSIPRouter Documentation](https://dsiprouter.readthedocs.io/en/latest)
For a list of updates and changes refer to our [Changelog](CHANGELOG.md)

### Contributing

See the [Contributing Guidelines](CONTRIBUTING.md) for more details
A current list of contributors can be found [here](CONTRIBUTORS.md)

### Getting Started

You can find the steps to install of support operating systems:

- [Debian Based Systems](https://dsiprouter.readthedocs.io/en/latest/debian_install.html#debian-install)
- [Redhat Based Systems](https://dsiprouter.readthedocs.io/en/latest/rhel_install.html#rhel-install)

### Support

- Free Support: [dSIPRouter Question & Answer Forum](https://groups.google.com/forum/#!forum/dsiprouter)
- Paid Support: [dSIPRouter Support](https://dsiprouter.org/#fh5co-support-section)

### Training

Details on training can be found [here](https://dopensource.com/product/dsiprouter-admin-course/)

### License

- Apache License 2.0, [read more here](LICENSE)

### Supported Features

- Carrier Management
  - Manage carriers as a group
- Endpoint Management
  - Manage endpoints as a group
  - Call Limiting per Endpoint Group
  - Call Detail Records generation per Endpoint Group
- Notification System
  - Over Call Limit Notifications
  - Endpoint Failure Notifications
  - Call Detail Record Notifications
- Enhanced DID Management
  - DID Failover to a Carrier/Endpoint Group or DID
  - DID Hard Forwarding to a Carrier/Endpoint Group or DID
  - Flowroute DID synchronization
- Enhanced Route Management
  - FusionPBX Domain Routing Enhancements
  - Outbound / Inbound DID prefix routing
  - Least Cost Locality Outbound routing
  - Load balancing / sequential routing via groups
  - Integration with your own custom Kamailio routes
  - E911 Priority routing
  - Local Extension routing
  - Voicemail routing
- Security
  - TLS Enabled by Default
  - Rate-limiting / DOS protection
  - Teleblock blacklist support
- High Availablity (Subscription Required)
  - Mysql Active-Active replication
  - Pacemaker / Corosync Active-Passive floating IP
  - Consul DNS Load-balancing and DNS Failover
  - dSIPRouter cluster synchronization
  - Kamailio DMQ replication
- Microsoft Teams Support (Subscription Required)
- WebSockets Enabled by Default
