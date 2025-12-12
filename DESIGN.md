# WebAuthn Passwordless Login for Proxmox

## Goal
Enable passkeys/WebAuthn as a standalone authentication method for Proxmox, bypassing password entry entirely.

## Project Structure

```
~/claude/pve-webauthn-login/
├── debian/
│   ├── control
│   ├── changelog
│   ├── rules
│   ├── copyright
│   ├── compat
│   └── pve-webauthn-login.install
├── src/
│   └── PVE/
│       └── WebAuthnLogin.pm
├── js/
│   └── webauthn-login.js
├── systemd/
│   └── pveproxy.service.d/
│       └── webauthn-login.conf
├── Makefile
└── README.md
```

## Architecture Overview

Create a self-contained Perl module that:
1. Registers new API endpoints for passwordless WebAuthn login
2. Monkey-patches pveproxy to serve custom JavaScript
3. Injects a script tag into the login page HTML

**No system files are modified** - everything lives in `/usr/local/` and `/etc/systemd/system/`.

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  Login Form     │────▶│ /webauthn-login/     │────▶│ Issue Ticket    │
│  (Passkey btn)  │     │ challenge + login    │     │ (like OpenID)   │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
```

## Files to Create

### 1. `/usr/local/share/perl/5.36.0/PVE/WebAuthnLogin.pm`
Custom Perl module that:
- Registers two API endpoints on `PVE::API2::AccessControl`
- Monkey-patches `PVE::Service::pveproxy::init` to add custom JS to `pages` config
- Monkey-patches `PVE::Service::pveproxy::get_index` to inject `<script>` tag
- Uses existing `PVE::RS::TFA` for WebAuthn crypto operations
- Uses `PVE::AccessControl::assemble_ticket()` to issue session tickets

### 2. `/etc/systemd/system/pveproxy.service.d/webauthn-login.conf`
Systemd drop-in to load our module at startup:
```ini
[Service]
Environment="PERL5OPT=-MPVE::WebAuthnLogin"
```

### 3. `/usr/local/share/pve-webauthn-login/webauthn-login.js`
Frontend JavaScript that adds "Login with Passkey" button. Served via pveproxy pages config.

---

## Detailed Implementation

### Part 1: Perl Backend Module

**File:** `/usr/local/share/perl/5.36.0/PVE/WebAuthnLogin.pm`

```perl
package PVE::WebAuthnLogin;

use strict;
use warnings;

use JSON;
use PVE::AccessControl;
use PVE::Cluster qw(cfs_read_file);
use PVE::Exception qw(raise);
use PVE::RPCEnvironment;
use PVE::SafeSyslog;
use PVE::API2::AccessControl;

# Path to our custom JS file
my $webauthn_js_path = '/usr/local/share/pve-webauthn-login/webauthn-login.js';

#############################################
# Part A: Monkey-patch pveproxy for JS injection
#############################################

BEGIN {
    require PVE::Service::pveproxy;

    # Store original functions
    my $original_init = \&PVE::Service::pveproxy::init;
    my $original_get_index = \&PVE::Service::pveproxy::get_index;

    # Override init to add our JS file to pages config
    no warnings 'redefine';
    *PVE::Service::pveproxy::init = sub {
        my ($self) = @_;
        $original_init->($self);

        # Add our custom JS file to pages (served without auth)
        if (-f $webauthn_js_path) {
            $self->{server_config}->{pages}->{'/webauthn-login.js'} = {
                file => $webauthn_js_path,
            };
        }
    };

    # Override get_index to inject script tag
    *PVE::Service::pveproxy::get_index = sub {
        my $resp = $original_get_index->(@_);

        if (-f $webauthn_js_path) {
            # Inject our script tag before </head>
            my $content = $resp->content;
            my $script_tag = '<script type="text/javascript" src="/webauthn-login.js"></script>';
            $content =~ s{</head>}{$script_tag\n</head>};
            $resp->content($content);
        }

        return $resp;
    };
    use warnings 'redefine';
}

#############################################
# Part B: Register API endpoints
#############################################

# GET /api2/json/access/webauthn-login/challenge
PVE::API2::AccessControl->register_method({
    name => 'webauthn_login_challenge',
    path => 'webauthn-login/challenge',
    method => 'POST',
    permissions => { user => 'world' },
    protected => 1,
    allowtoken => 0,
    description => "Get WebAuthn challenge for passwordless login.",
    parameters => {
        additionalProperties => 0,
        properties => {
            username => {
                description => "Full user name (user@realm)",
                type => 'string',
                maxLength => 64,
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            challenge => { type => 'string' },
            ticket => { type => 'string' },
        },
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $username = PVE::AccessControl::lookup_username($param->{username});

        # Verify user exists and is enabled
        $rpcenv->check_user_enabled($username);

        # Get user's TFA config
        my ($tfa_cfg, $realm_tfa) = PVE::AccessControl::user_get_tfa($username, undef);
        die "user has no TFA configured\n" if !$tfa_cfg;

        # Configure WebAuthn settings
        PVE::AccessControl::configure_u2f_and_wa($tfa_cfg);

        # Generate WebAuthn challenge
        my $challenge = $tfa_cfg->authentication_challenge($username);
        die "user has no WebAuthn credentials\n" if !$challenge;

        # Check if challenge contains webauthn
        my $challenge_data = decode_json($challenge);
        die "no WebAuthn credentials registered\n" unless $challenge_data->{webauthn};

        # Create a signed ticket containing the challenge
        my $ticket = PVE::AccessControl::assemble_ticket("!waLogin!$challenge", $username);

        return {
            challenge => $challenge,
            ticket => $ticket,
        };
    },
});

# POST /api2/json/access/webauthn-login/login
PVE::API2::AccessControl->register_method({
    name => 'webauthn_login',
    path => 'webauthn-login/login',
    method => 'POST',
    permissions => { user => 'world' },
    protected => 1,
    allowtoken => 0,
    description => "Verify WebAuthn response and create authentication ticket.",
    parameters => {
        additionalProperties => 0,
        properties => {
            username => {
                description => "Full user name (user@realm)",
                type => 'string',
                maxLength => 64,
            },
            'challenge-ticket' => {
                description => "The challenge ticket from the challenge endpoint",
                type => 'string',
            },
            response => {
                description => "The WebAuthn response JSON",
                type => 'string',
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            ticket => { type => 'string' },
            username => { type => 'string' },
            CSRFPreventionToken => { type => 'string' },
            cap => { type => 'object' },
        },
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $username = PVE::AccessControl::lookup_username($param->{username});
        my $clientip = $rpcenv->get_client_ip() || '';

        my $res;
        eval {
            # Verify user is enabled
            $rpcenv->check_user_enabled($username);

            # Verify the challenge ticket
            my $ticket_data = PVE::AccessControl::verify_ticket(
                $param->{'challenge-ticket'}, 0, $username
            );

            die "invalid challenge ticket\n" unless $ticket_data =~ s/^!waLogin!//;
            my $challenge = $ticket_data;

            # Get TFA config and configure WebAuthn
            my ($tfa_cfg, $realm_tfa) = PVE::AccessControl::user_get_tfa($username, undef);
            PVE::AccessControl::configure_u2f_and_wa($tfa_cfg);

            # Verify the WebAuthn response
            my $tfa_response = "webauthn:" . $param->{response};
            my $result = $tfa_cfg->authentication_verify2(
                $username, $challenge, $tfa_response
            );

            die "WebAuthn verification failed\n" unless $result->{result};

            # Save TFA state if needed (e.g., counter update)
            if ($result->{'needs-saving'}) {
                PVE::Cluster::cfs_write_file('priv/tfa.cfg', $tfa_cfg);
            }

            # Issue the authentication ticket
            my $ticket = PVE::AccessControl::assemble_ticket($username);
            my $csrftoken = PVE::AccessControl::assemble_csrf_prevention_token($username);
            my $cap = $rpcenv->compute_api_permission($username);

            $res = {
                ticket => $ticket,
                username => $username,
                CSRFPreventionToken => $csrftoken,
                cap => $cap,
            };

            PVE::Cluster::log_msg('info', 'root@pam',
                "successful webauthn login for user '$username'");
        };

        if (my $err = $@) {
            syslog('err', "webauthn login failure; rhost=$clientip user=$username msg=$err");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        return $res;
    },
});

1;
```

### Part 2: Systemd Integration

**File:** `/etc/systemd/system/pveproxy.service.d/webauthn-login.conf`

```ini
[Service]
Environment="PERL5OPT=-MPVE::WebAuthnLogin"
```

### Part 3: Frontend JavaScript

**File:** `/usr/local/share/pve-webauthn-login/webauthn-login.js`

This script runs after pvemanagerlib.js loads and patches the LoginWindow:

```javascript
// WebAuthn Passwordless Login for Proxmox
// Injected by PVE::WebAuthnLogin module

(function() {
    'use strict';

    // Wait for Ext and PVE to be ready
    Ext.onReady(function() {
        // Override PVE.window.LoginWindow to add WebAuthn button
        Ext.override(PVE.window.LoginWindow, {
            initComponent: function() {
                this.callParent(arguments);

                // Add WebAuthn login button after form is created
                let form = this.lookupReference('loginForm');
                if (form) {
                    let btnContainer = form.down('container[cls~=x-form-buttons]') || form;

                    btnContainer.add({
                        xtype: 'button',
                        text: gettext('Login with Passkey'),
                        iconCls: 'fa fa-key',
                        margin: '0 0 0 10',
                        handler: 'onWebAuthnLogin'
                    });
                }
            }
        });

        // Add the WebAuthn login handler to the controller
        let loginController = Ext.ClassManager.get('PVE.window.LoginWindow').prototype.controller;
        if (loginController) {
            Ext.apply(loginController, {
                onWebAuthnLogin: async function() {
                    let me = this;
                    let view = me.getView();
                    let usernameField = me.lookupReference('usernameField');
                    let realmField = me.lookupReference('realmField');

                    // Get username from field or saved state
                    let username = usernameField.getValue();
                    if (!username) {
                        let sp = Ext.state.Manager.getProvider();
                        username = sp.get(usernameField.getStateId());
                    }

                    if (!username) {
                        Ext.Msg.alert(gettext('Error'), gettext('Please enter a username'));
                        return;
                    }

                    let realm = realmField.getValue() || 'pam';
                    let fullUsername = username.includes('@') ? username : username + '@' + realm;

                    view.el.mask(gettext('Authenticating...'), 'x-mask-loading');

                    try {
                        // Step 1: Get WebAuthn challenge
                        let challengeResp = await Proxmox.Async.api2({
                            url: '/api2/extjs/access/webauthn-login/challenge',
                            method: 'POST',
                            params: { username: fullUsername }
                        });

                        let challengeData = JSON.parse(challengeResp.result.data.challenge);
                        let ticket = challengeResp.result.data.ticket;

                        // Step 2: Prepare challenge for WebAuthn API
                        let publicKey = challengeData.webauthn.publicKey;
                        publicKey.challenge = Proxmox.Utils.base64url_to_bytes(publicKey.challenge);

                        if (publicKey.allowCredentials) {
                            for (let cred of publicKey.allowCredentials) {
                                cred.id = Proxmox.Utils.base64url_to_bytes(cred.id);
                            }
                        }

                        // Step 3: Invoke WebAuthn (Passkey prompt)
                        let assertion = await navigator.credentials.get({ publicKey });

                        // Step 4: Format response for server
                        let response = {
                            id: assertion.id,
                            type: assertion.type,
                            challenge: challengeData.webauthn.string,
                            rawId: Proxmox.Utils.bytes_to_base64url(
                                new Uint8Array(assertion.rawId)
                            ),
                            response: {
                                authenticatorData: Proxmox.Utils.bytes_to_base64url(
                                    new Uint8Array(assertion.response.authenticatorData)
                                ),
                                clientDataJSON: Proxmox.Utils.bytes_to_base64url(
                                    new Uint8Array(assertion.response.clientDataJSON)
                                ),
                                signature: Proxmox.Utils.bytes_to_base64url(
                                    new Uint8Array(assertion.response.signature)
                                )
                            }
                        };

                        // Step 5: Complete login
                        let loginResp = await Proxmox.Async.api2({
                            url: '/api2/extjs/access/webauthn-login/login',
                            method: 'POST',
                            params: {
                                username: fullUsername,
                                'challenge-ticket': ticket,
                                response: JSON.stringify(response)
                            }
                        });

                        view.el.unmask();
                        me.success(loginResp.result.data);

                    } catch (err) {
                        view.el.unmask();

                        let msg = err.message || gettext('Authentication failed');
                        if (err.result && err.result.message) {
                            msg = err.result.message;
                        }

                        // Don't show error if user cancelled
                        if (err.name !== 'NotAllowedError') {
                            Ext.Msg.alert(gettext('WebAuthn Error'), msg);
                        }
                    }
                }
            });
        }
    });
})();
```

---

## Implementation Steps

1. **Create directories:**
   ```bash
   ssh root@proxmox.lan "mkdir -p /usr/local/share/perl/5.36.0/PVE"
   ssh root@proxmox.lan "mkdir -p /usr/local/share/pve-webauthn-login"
   ssh root@proxmox.lan "mkdir -p /etc/systemd/system/pveproxy.service.d"
   ```

2. **Deploy Perl module** to `/usr/local/share/perl/5.36.0/PVE/WebAuthnLogin.pm`

3. **Deploy JavaScript** to `/usr/local/share/pve-webauthn-login/webauthn-login.js`

4. **Create systemd drop-in** at `/etc/systemd/system/pveproxy.service.d/webauthn-login.conf`

5. **Reload and restart:**
   ```bash
   systemctl daemon-reload
   systemctl restart pveproxy
   ```

6. **Test API endpoints:**
   ```bash
   curl -k https://proxmox.example.com/api2/json/access/webauthn-login/challenge \
     -d 'username=root@pam'
   ```

7. **Test end-to-end** in browser

---

## Update Resilience

All files survive Proxmox updates:
- `/usr/local/share/perl/5.36.0/PVE/WebAuthnLogin.pm` - not touched by packages
- `/usr/local/share/pve-webauthn-login/webauthn-login.js` - not touched by packages
- `/etc/systemd/system/pveproxy.service.d/webauthn-login.conf` - standard override location

---

## Security Considerations

- WebAuthn challenge includes timeout (60 seconds default)
- Challenge ticket is cryptographically signed with Proxmox's RSA key
- Only users with registered WebAuthn credentials can use this flow
- User must still exist and be enabled in Proxmox
- Origin verification handled by WebAuthn standard
- All existing Proxmox auth logging is preserved

---

## Rollback

To disable:
```bash
rm /etc/systemd/system/pveproxy.service.d/webauthn-login.conf
systemctl daemon-reload
systemctl restart pveproxy
```

To fully remove:
```bash
apt remove pve-webauthn-login
# or manually:
rm -rf /usr/local/share/perl/5.36.0/PVE/WebAuthnLogin.pm
rm -rf /usr/local/share/pve-webauthn-login/
rm /etc/systemd/system/pveproxy.service.d/webauthn-login.conf
systemctl daemon-reload
systemctl restart pveproxy
```

---

## Debian Packaging

### debian/control
```
Source: pve-webauthn-login
Section: admin
Priority: optional
Maintainer: Your Name <your@email.com>
Build-Depends: debhelper (>= 10)
Standards-Version: 4.1.3

Package: pve-webauthn-login
Architecture: all
Depends: ${misc:Depends}, proxmox-ve (>= 8.0)
Description: WebAuthn passwordless login for Proxmox VE
 Enables passkeys and other WebAuthn authenticators as a standalone
 login method for Proxmox VE, bypassing password entry.
```

### debian/rules
```makefile
#!/usr/bin/make -f
%:
	dh $@

override_dh_auto_install:
	install -D -m 644 src/PVE/WebAuthnLogin.pm \
		debian/pve-webauthn-login/usr/local/share/perl/5.36.0/PVE/WebAuthnLogin.pm
	install -D -m 644 js/webauthn-login.js \
		debian/pve-webauthn-login/usr/local/share/pve-webauthn-login/webauthn-login.js
	install -D -m 644 systemd/pveproxy.service.d/webauthn-login.conf \
		debian/pve-webauthn-login/etc/systemd/system/pveproxy.service.d/webauthn-login.conf
```

### debian/postinst
```bash
#!/bin/bash
set -e
systemctl daemon-reload
systemctl restart pveproxy || true
```

### debian/postrm
```bash
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    systemctl daemon-reload
    systemctl restart pveproxy || true
fi
```

### Build and Install
```bash
# Build the package
cd ~/claude/pve-webauthn-login
dpkg-buildpackage -us -uc -b

# Copy to Proxmox and install
scp ../pve-webauthn-login_*.deb root@proxmox.lan:/tmp/
ssh root@proxmox.lan "dpkg -i /tmp/pve-webauthn-login_*.deb"
```
