package PVE::WebAuthnLogin;

use strict;
use warnings;

use JSON;
use PVE::AccessControl;
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Exception qw(raise);
use PVE::RPCEnvironment;
use PVE::SafeSyslog;
use PVE::API2::AccessControl;

# Path to our custom JS file
my $webauthn_js_path = '/usr/local/share/pve-webauthn-login/webauthn-login.js';

# Path to EOL status file (written by update script when EOL detected)
my $eol_file_path = '/var/lib/pve-webauthn-login/eol.json';

# Track which parts loaded successfully
our $auth_handler_patched = 0;
our $api_endpoints_registered = 0;

#############################################
# Part A: Monkey-patch HTTPServer for auth bypass
# This works for BOTH pveproxy AND pvedaemon
#############################################

BEGIN {
    eval {
        # Load HTTPServer FIRST before any service loads it
        require PVE::HTTPServer;

        # Now override auth_handler BEFORE services use it
        my $original_auth_handler = \&PVE::HTTPServer::auth_handler;

        no warnings 'redefine';

        # Override auth_handler to allow our WebAuthn endpoints without authentication
        *PVE::HTTPServer::auth_handler = sub {
        my ($self, $method, $rel_uri, $ticket, $token, $api_token, $peer_host) = @_;

        my $rpcenv = $self->{rpcenv};

        # set environment variables
        $rpcenv->set_user(undef);
        $rpcenv->set_language('C');
        $rpcenv->set_client_ip($peer_host);

        eval { $rpcenv->init_request() };
        PVE::Exception::raise("RPCEnvironment init request failed: $@\n") if $@;

        my $require_auth = 1;

        # Allow our WebAuthn endpoints without authentication (in addition to standard ones)
        if (($rel_uri eq '/access/webauthn-challenge' && $method eq 'POST')
            || ($rel_uri eq '/access/webauthn-login' && $method eq 'POST')
            || ($rel_uri eq '/access/domains' && $method eq 'GET')
            || ($rel_uri eq '/access/ticket' && ($method eq 'GET' || $method eq 'POST'))
            || ($rel_uri eq '/access/vncticket' && $method eq 'POST')
            || ($rel_uri eq '/access/openid/login' && $method eq 'POST')
            || ($rel_uri eq '/access/openid/auth-url' && $method eq 'POST')
        ) {
            $require_auth = 0;
        }

        my ($username, $age);
        my $isUpload = 0;

        if ($require_auth) {
            if ($api_token) {
                $username = PVE::AccessControl::verify_token($api_token);
            } else {
                die "No ticket\n" if !$ticket;

                ($username, $age, my $tfa_info) = PVE::AccessControl::verify_ticket($ticket);
                $rpcenv->check_user_enabled($username);

                if (defined($tfa_info)) {
                    if (defined(my $challenge = $tfa_info->{challenge})) {
                        $rpcenv->set_u2f_challenge($challenge);
                    }
                    die "No ticket\n" if ($rel_uri ne '/access/tfa' || $method ne 'POST');
                }
            }

            $rpcenv->set_user($username);

            if ($method eq 'POST' && $rel_uri =~ m|^/nodes/([^/]+)/storage/([^/]+)/upload$|) {
                my ($node, $storeid) = ($1, $2);
                my $perm = { check => ['perm', "/storage/$storeid", ['Datastore.AllocateTemplate']] };
                $rpcenv->check_api2_permissions($perm, $username, {});
                $isUpload = 1;
            }

            if ($method ne 'GET' && !($api_token || $isUpload)) {
                my $euid = $>;
                PVE::AccessControl::verify_csrf_prevention_token($username, $token) if $euid != 0;
            }
        }

        return {
            ticket => $ticket,
            token => $token,
            userid => $username,
            age => $age,
            isUpload => $isUpload,
            api_token => $api_token,
        };
    };

        use warnings 'redefine';
        $PVE::WebAuthnLogin::auth_handler_patched = 1;
    };
    if ($@) {
        warn "pve-webauthn-login: Failed to patch auth handler: $@";
    }
}

#############################################
# Part B: Monkey-patch pveproxy for JS injection
# (only applies when loaded by pveproxy)
#############################################

our $pveproxy_patched = 0;

sub patch_pveproxy {
    eval {
        require PVE::Service::pveproxy;

        # Store original functions for pveproxy
        my $original_init = \&PVE::Service::pveproxy::init;
        my $original_get_index = \&PVE::Service::pveproxy::get_index;

        no warnings 'redefine';

        # Override init to add our JS file to pages config
        *PVE::Service::pveproxy::init = sub {
            my ($self) = @_;
            $original_init->($self);

            # Add our custom JS file to pages (served without auth)
            if (-f $webauthn_js_path) {
                $self->{server_config}->{pages}->{'/webauthn-login.js'} = {
                    file => $webauthn_js_path,
                };
            }

            # Add EOL status file if it exists (served without auth)
            if (-f $eol_file_path) {
                $self->{server_config}->{pages}->{'/webauthn-eol.json'} = {
                    file => $eol_file_path,
                };
            }
        };

        # Override get_index to inject script tag
        *PVE::Service::pveproxy::get_index = sub {
            my $resp = $original_get_index->(@_);

            if (-f $webauthn_js_path) {
                my $content = $resp->content;
                my $script_tag = '<script type="text/javascript" src="/webauthn-login.js"></script>';

                # Inject BEFORE the inline Ext.onReady script that creates PVE.StdWorkspace
                # This ensures our override is in place before the login window is created
                if ($content =~ s{(pvemanagerlib\.js[^>]*></script>)}{$1\n    $script_tag}s) {
                    # Successfully injected after pvemanagerlib.js
                } else {
                    # Fallback: inject before </head>
                    $content =~ s{</head>}{$script_tag\n</head>};
                }
                $resp->content($content);
            }

            return $resp;
        };

        use warnings 'redefine';
        $pveproxy_patched = 1;
    };
    if ($@) {
        warn "pve-webauthn-login: Failed to patch pveproxy: $@";
    }
}

#############################################
# Part C: Register API endpoints
#############################################

eval {

# POST /api2/json/access/webauthn-challenge
PVE::API2::AccessControl->register_method({
    name => 'webauthn_login_challenge',
    path => 'webauthn-challenge',
    method => 'POST',
    permissions => { user => 'world' },
    protected => 1,
    allowtoken => 0,
    description => "Get WebAuthn challenge for passwordless login.",
    parameters => {
        additionalProperties => 0,
        properties => {
            username => {
                description => "Full user name (user\@realm)",
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
        my $clientip = $rpcenv->get_client_ip() || '';

        # Lookup username - treat unknown users same as disabled (prevent enumeration)
        my $username;
        eval {
            $username = PVE::AccessControl::lookup_username($param->{username});
        };
        if ($@) {
            syslog('err', "webauthn challenge failure; rhost=$clientip user=$param->{username} msg=lookup failed");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Verify user exists and is enabled (auth failure - generic message)
        eval {
            $rpcenv->check_user_enabled($username);
        };
        if (my $err = $@) {
            syslog('err', "webauthn challenge failure; rhost=$clientip user=$username msg=$err");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Get user's TFA config (our failure if this fails unexpectedly)
        my $tfa_cfg;
        eval {
            $tfa_cfg = cfs_read_file('priv/tfa.cfg');
        };
        if ($@ || !$tfa_cfg) {
            syslog('err', "pve-webauthn-login: Failed to read TFA config: " . ($@ || 'empty'));
            die PVE::Exception->new("Passkey authentication unavailable, possibly due to a version conflict. Check for updates or see syslog.\n", code => 500);
        }

        # Configure WebAuthn settings (config failure - specific message)
        eval {
            PVE::AccessControl::configure_u2f_and_wa($tfa_cfg);
        };
        if ($@) {
            syslog('err', "pve-webauthn-login: WebAuthn configuration error: $@");
            die PVE::Exception->new("WebAuthn is not configured. Check Datacenter -> Options -> WebAuthn Settings.\n", code => 500);
        }

        # Generate WebAuthn challenge (auth failure if user has no credentials)
        my $challenge;
        eval {
            $challenge = $tfa_cfg->authentication_challenge($username);
        };
        if ($@) {
            syslog('err', "pve-webauthn-login: Challenge generation error: $@");
            die PVE::Exception->new("Passkey authentication unavailable, possibly due to a version conflict. Check for updates or see syslog.\n", code => 500);
        }
        if (!$challenge) {
            syslog('err', "webauthn challenge failure; rhost=$clientip user=$username msg=no credentials");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Check if challenge contains webauthn (auth failure - user may only have TOTP)
        my $challenge_data;
        eval {
            $challenge_data = decode_json($challenge);
        };
        if ($@ || !$challenge_data->{webauthn}) {
            syslog('err', "webauthn challenge failure; rhost=$clientip user=$username msg=no webauthn credentials");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Create a signed ticket containing the challenge
        my $ticket;
        eval {
            $ticket = PVE::AccessControl::assemble_ticket("!tfa!waLogin!$challenge", $username);
        };
        if ($@) {
            syslog('err', "pve-webauthn-login: Ticket assembly failed: $@");
            die PVE::Exception->new("Passkey authentication unavailable, possibly due to a version conflict. Check for updates or see syslog.\n", code => 500);
        }

        return {
            challenge => $challenge,
            ticket => $ticket,
        };
    },
});

# POST /api2/json/access/webauthn-login
PVE::API2::AccessControl->register_method({
    name => 'webauthn_login',
    path => 'webauthn-login',
    method => 'POST',
    permissions => { user => 'world' },
    protected => 1,
    allowtoken => 0,
    description => "Verify WebAuthn response and create authentication ticket.",
    parameters => {
        additionalProperties => 0,
        properties => {
            username => {
                description => "Full user name (user\@realm)",
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
        my $clientip = $rpcenv->get_client_ip() || '';

        # Lookup username - treat unknown users same as disabled (prevent enumeration)
        my $username;
        eval {
            $username = PVE::AccessControl::lookup_username($param->{username});
        };
        if ($@) {
            syslog('err', "webauthn login failure; rhost=$clientip user=$param->{username} msg=lookup failed");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Verify user is enabled (auth failure - generic)
        eval {
            $rpcenv->check_user_enabled($username);
        };
        if ($@) {
            syslog('err', "webauthn login failure; rhost=$clientip user=$username msg=$@");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Verify the challenge ticket (auth failure - could be expired or tampered)
        my $challenge;
        eval {
            my ($ticket_data, $ticket_age) = PVE::AccessControl::verify_ticket(
                $param->{'challenge-ticket'}, 0, $username
            );

            die "invalid challenge ticket\n" if !defined($ticket_data);
            # verify_ticket strips !tfa! prefix, so we expect waLogin! prefix now
            die "invalid challenge ticket\n" unless $ticket_data =~ s/^waLogin!//;
            $challenge = $ticket_data;
        };
        if ($@) {
            syslog('err', "webauthn login failure; rhost=$clientip user=$username msg=$@");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Get TFA config
        my $tfa_cfg;
        eval {
            $tfa_cfg = cfs_read_file('priv/tfa.cfg');
            PVE::AccessControl::configure_u2f_and_wa($tfa_cfg);
        };
        if ($@) {
            syslog('err', "pve-webauthn-login: TFA config error during login: $@");
            die PVE::Exception->new("Passkey authentication unavailable, possibly due to a version conflict. Check for updates or see syslog.\n", code => 500);
        }

        # Verify the WebAuthn response (auth failure if verification fails)
        my $result;
        eval {
            my $tfa_response = "webauthn:" . $param->{response};
            $result = $tfa_cfg->authentication_verify2(
                $username, $challenge, $tfa_response
            );
        };
        if ($@ || !$result->{result}) {
            my $err = $@ || "verification failed";
            syslog('err', "webauthn login failure; rhost=$clientip user=$username msg=$err");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Save TFA state if needed (e.g., counter update) - non-fatal if fails
        if ($result->{'needs-saving'}) {
            eval {
                cfs_write_file('priv/tfa.cfg', $tfa_cfg);
            };
            if ($@) {
                syslog('warning', "pve-webauthn-login: Failed to save TFA state: $@");
                # Continue anyway - login succeeded
            }
        }

        # Issue the authentication ticket
        my $res;
        eval {
            my $ticket = PVE::AccessControl::assemble_ticket($username);
            my $csrftoken = PVE::AccessControl::assemble_csrf_prevention_token($username);
            my $cap = $rpcenv->compute_api_permission($username);

            $res = {
                ticket => $ticket,
                username => $username,
                CSRFPreventionToken => $csrftoken,
                cap => $cap,
            };
        };
        if ($@) {
            syslog('err', "pve-webauthn-login: Ticket/token generation failed: $@");
            die PVE::Exception->new("Passkey authentication unavailable, possibly due to a version conflict. Check for updates or see syslog.\n", code => 500);
        }

        PVE::Cluster::log_msg('info', 'root@pam',
            "successful webauthn login for user '$username'");

        return $res;
    },
});

$api_endpoints_registered = 1;
};
if ($@) {
    warn "pve-webauthn-login: Failed to register API endpoints: $@";
}

1;
