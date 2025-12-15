// WebAuthn Passwordless Login for Proxmox VE
// Adds a "Login with Passkey" button to the Proxmox login window

(function init() {
    'use strict';

    // Wait for Ext to be ready
    if (typeof Ext === 'undefined') {
        console.log('WebAuthn Login: Ext not found, retrying...');
        setTimeout(init, 100);
        return;
    }

    Ext.onReady(function() {
        console.log('WebAuthn Login: Ext ready, setting up...');

        // EOL Banner - check for EOL status file and display warning if present
        var checkAndShowEolBanner = function() {
            // Check if banner already exists
            if (Ext.get('pve-webauthn-eol-banner')) {
                return;
            }

            // Check if user dismissed the banner this session
            if (window.sessionStorage && window.sessionStorage.getItem('pve-webauthn-eol-dismissed')) {
                return;
            }

            // Fetch EOL status file (only exists if EOL was detected by update script)
            fetch('/webauthn-eol.json')
                .then(function(response) {
                    if (!response.ok) {
                        // File doesn't exist = not EOL
                        return null;
                    }
                    return response.json();
                })
                .then(function(eolData) {
                    if (!eolData) {
                        return;
                    }

                    var message = eolData.message || 'This module is no longer maintained.';

                    Ext.DomHelper.insertFirst(document.body, {
                        id: 'pve-webauthn-eol-banner',
                        tag: 'div',
                        style: 'position: fixed; top: 0; left: 0; right: 0; z-index: 100000; ' +
                               'background: linear-gradient(135deg, #d32f2f 0%, #b71c1c 100%); ' +
                               'color: white; padding: 12px 20px; text-align: center; ' +
                               'font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; ' +
                               'font-size: 14px; box-shadow: 0 2px 8px rgba(0,0,0,0.3);',
                        html: '<span style="margin-right: 15px;">' +
                              '<strong>pve-webauthn-login has reached end-of-life.</strong> ' +
                              Ext.htmlEncode(message) + ' To uninstall: ' +
                              '<code style="background: rgba(255,255,255,0.2); padding: 2px 8px; border-radius: 3px; font-family: monospace;">apt remove pve-webauthn-login</code>' +
                              '</span>' +
                              '<button id="pve-webauthn-eol-dismiss" style="background: rgba(255,255,255,0.2); border: 1px solid rgba(255,255,255,0.4); ' +
                              'color: white; padding: 4px 12px; border-radius: 3px; cursor: pointer; font-size: 12px;">Dismiss</button>'
                    });

                    // Add dismiss handler
                    Ext.get('pve-webauthn-eol-dismiss').on('click', function() {
                        Ext.get('pve-webauthn-eol-banner').remove();
                        // Remember dismissal for this session
                        if (window.sessionStorage) {
                            window.sessionStorage.setItem('pve-webauthn-eol-dismissed', 'true');
                        }
                    });
                })
                .catch(function() {
                    // Silently ignore fetch errors (file doesn't exist = not EOL)
                });
        };

        // Check for EOL status
        checkAndShowEolBanner();

        // Function to add button to an existing login window
        var addButtonToWindow = function(loginWindow) {
            // Find the login button
            var loginBtn = loginWindow.down('button[reference=loginButton]');
            if (!loginBtn) {
                console.log('WebAuthn Login: loginButton not found in window');
                return false;
            }

            // Check if we already added the button
            if (loginWindow.down('button[itemId=webauthnLoginBtn]')) {
                console.log('WebAuthn Login: Button already exists');
                return true;
            }

            // Find the container and add our button
            var container = loginBtn.ownerCt;
            if (container) {
                var idx = container.items.indexOf(loginBtn);
                container.insert(idx + 1, {
                    xtype: 'button',
                    itemId: 'webauthnLoginBtn',
                    text: gettext('Login with Passkey'),
                    iconCls: 'fa fa-key',
                    margin: '0 0 0 5',
                    handler: function() {
                        doWebAuthnLogin(loginWindow);
                    }
                });
                console.log('WebAuthn Login: Button added successfully');
                return true;
            }
            return false;
        };

        // Try to find existing login window
        var findAndPatchLoginWindow = function() {
            // Look for any existing LoginWindow instances
            var windows = Ext.ComponentQuery.query('window');
            for (var i = 0; i < windows.length; i++) {
                var win = windows[i];
                if (win.$className === 'PVE.window.LoginWindow' ||
                    (win.title && win.title.indexOf('Login') >= 0) ||
                    win.lookupReference('loginForm')) {
                    console.log('WebAuthn Login: Found login window');
                    if (addButtonToWindow(win)) {
                        return true;
                    }
                }
            }
            return false;
        };

        // Also override for future instances
        var patchLoginWindowClass = function() {
            if (!Ext.ClassManager.get('PVE.window.LoginWindow')) {
                return;
            }

            var originalInitComponent = PVE.window.LoginWindow.prototype.initComponent;
            PVE.window.LoginWindow.prototype.initComponent = function() {
                var me = this;
                originalInitComponent.apply(me, arguments);

                // Add button after a short delay
                Ext.defer(function() {
                    addButtonToWindow(me);
                }, 100);
            };
            console.log('WebAuthn Login: Patched LoginWindow class');
        };

        // WebAuthn login handler
        var doWebAuthnLogin = async function(loginWindow) {
            var controller = loginWindow.getController();
            var usernameField = controller ? controller.lookupReference('usernameField') : loginWindow.down('field[name=username]');
            var realmField = controller ? controller.lookupReference('realmField') : loginWindow.down('field[name=realm]');

            // Get username from field or saved state
            var username = usernameField ? usernameField.getValue() : '';
            if (!username) {
                var sp = Ext.state.Manager.getProvider();
                if (sp && usernameField) {
                    username = sp.get(usernameField.getStateId());
                }
            }

            if (!username) {
                Ext.Msg.alert(gettext('Error'), gettext('A username is required for Passkey logins.'));
                return;
            }

            var realm = realmField ? realmField.getValue() : 'pam';
            if (!realm) {
                realm = 'pam';
            }
            var fullUsername = username.indexOf('@') >= 0 ? username : username + '@' + realm;

            // Save username if "Save User name" is checked (same as normal login)
            var saveunField = controller ? controller.lookupReference('saveunField') : loginWindow.down('field[name=saveusername]');
            var sp = Ext.state.Manager.getProvider();
            if (sp && saveunField && usernameField) {
                if (saveunField.getValue() === true) {
                    sp.set(usernameField.getStateId(), usernameField.getValue());
                } else {
                    sp.clear(usernameField.getStateId());
                }
                sp.set(saveunField.getStateId(), saveunField.getValue());
            }

            loginWindow.el.mask(gettext('Authenticating...'), 'x-mask-loading');

            try {
                // Step 1: Get WebAuthn challenge from server
                console.log('WebAuthn Login: Requesting challenge for', fullUsername);
                var challengeResp = await Proxmox.Async.api2({
                    url: '/api2/extjs/access/webauthn-challenge',
                    method: 'POST',
                    params: { username: fullUsername }
                });

                var challengeData = JSON.parse(challengeResp.result.data.challenge);
                var ticket = challengeResp.result.data.ticket;

                // Step 2: Prepare challenge for WebAuthn API
                var publicKey = challengeData.webauthn.publicKey;
                // Save challenge string before converting to bytes (needed for response)
                publicKey.challenge_str = publicKey.challenge;
                publicKey.challenge = Proxmox.Utils.base64url_to_bytes(publicKey.challenge);

                if (publicKey.allowCredentials) {
                    for (var i = 0; i < publicKey.allowCredentials.length; i++) {
                        var cred = publicKey.allowCredentials[i];
                        cred.id = Proxmox.Utils.base64url_to_bytes(cred.id);
                    }
                }

                // Step 3: Invoke WebAuthn (TouchID/Passkey prompt)
                console.log('WebAuthn Login: Requesting credential assertion...');
                var assertion = await navigator.credentials.get({ publicKey: publicKey });

                // Step 4: Format response for server
                // Must include challenge string for server-side verification
                var response = {
                    id: assertion.id,
                    type: assertion.type,
                    challenge: publicKey.challenge_str,
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

                // Step 5: Complete login with server
                console.log('WebAuthn Login: Verifying assertion...');
                var loginResp = await Proxmox.Async.api2({
                    url: '/api2/extjs/access/webauthn-login',
                    method: 'POST',
                    params: {
                        username: fullUsername,
                        'challenge-ticket': ticket,
                        response: JSON.stringify(response)
                    }
                });

                loginWindow.el.unmask();
                console.log('WebAuthn Login: Success!');

                // Call the controller's success method to complete login
                if (controller && controller.success) {
                    controller.success(loginResp.result.data);
                } else {
                    // Fallback: set auth data manually
                    Proxmox.Utils.setAuthData(loginResp.result.data);
                    window.location.reload();
                }

            } catch (err) {
                loginWindow.el.unmask();
                console.log('WebAuthn Login: Error', err);

                // Don't show error if user cancelled
                if (err.name === 'NotAllowedError' ||
                    (err.message && err.message.indexOf('cancelled') >= 0)) {
                    return;
                }

                var msg = gettext('Authentication failed');
                var title = gettext('WebAuthn Error');

                // Check for specific error conditions
                if (err.status === 404) {
                    // Endpoint not registered - module likely didn't load
                    title = gettext('Passkey Unavailable');
                    msg = gettext('Passkey login is temporarily unavailable. Check github.com/chall37/pve-webauthn-login for updates.');
                } else if (err.status === 500) {
                    // Server-side error - show the message from server if available
                    title = gettext('Passkey Error');
                    if (err.result && err.result.message) {
                        msg = err.result.message;
                    } else {
                        msg = gettext('Passkey login encountered an error. Check syslog for details.');
                    }
                } else if (err.result && err.result.message) {
                    msg = err.result.message;
                } else if (err.message) {
                    msg = err.message;
                }

                Ext.Msg.alert(title, msg);
            }
        };

        // Patch the class for future instances
        patchLoginWindowClass();

        // Try to find and patch existing window immediately
        if (!findAndPatchLoginWindow()) {
            // If not found, try again after a delay (window might be creating)
            console.log('WebAuthn Login: No login window found yet, will retry...');
            var retryCount = 0;
            var retryInterval = setInterval(function() {
                retryCount++;
                if (findAndPatchLoginWindow() || retryCount > 50) {
                    clearInterval(retryInterval);
                    if (retryCount > 50) {
                        console.log('WebAuthn Login: Gave up looking for login window');
                    }
                }
            }, 100);
        }
    });
})();
