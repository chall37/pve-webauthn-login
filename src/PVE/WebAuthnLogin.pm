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

#############################################
# Part A: Monkey-patch HTTPServer for auth bypass
# This works for BOTH pveproxy AND pvedaemon
#############################################

BEGIN {
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
}

#############################################
# Part B: Monkey-patch pveproxy for JS injection
# (only applies when loaded by pveproxy)
#############################################

sub patch_pveproxy {
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
}

#############################################
# Part C: Register API endpoints
#############################################

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
        my $username = PVE::AccessControl::lookup_username($param->{username});
        my $clientip = $rpcenv->get_client_ip() || '';

        eval {
            # Verify user exists and is enabled
            $rpcenv->check_user_enabled($username);
        };
        if (my $err = $@) {
            syslog('err', "webauthn challenge failure; rhost=$clientip user=$username msg=$err");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Get user's TFA config
        my $tfa_cfg = cfs_read_file('priv/tfa.cfg');
        die PVE::Exception->new("authentication failure\n", code => 401) if !$tfa_cfg;

        # Configure WebAuthn settings
        PVE::AccessControl::configure_u2f_and_wa($tfa_cfg);

        # Generate WebAuthn challenge
        my $challenge = $tfa_cfg->authentication_challenge($username);
        if (!$challenge) {
            syslog('err', "webauthn challenge failure; rhost=$clientip user=$username msg=no credentials");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Check if challenge contains webauthn
        my $challenge_data = decode_json($challenge);
        if (!$challenge_data->{webauthn}) {
            syslog('err', "webauthn challenge failure; rhost=$clientip user=$username msg=no webauthn");
            die PVE::Exception->new("authentication failure\n", code => 401);
        }

        # Create a signed ticket containing the challenge
        # Use !tfa! prefix so verify_ticket returns the data when called with AAD
        my $ticket = PVE::AccessControl::assemble_ticket("!tfa!waLogin!$challenge", $username);

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
        my $username = PVE::AccessControl::lookup_username($param->{username});
        my $clientip = $rpcenv->get_client_ip() || '';

        my $res;
        eval {
            # Verify user is enabled
            $rpcenv->check_user_enabled($username);

            # Verify the challenge ticket
            my ($ticket_data, $ticket_age) = PVE::AccessControl::verify_ticket(
                $param->{'challenge-ticket'}, 0, $username
            );

            die "invalid challenge ticket\n" if !defined($ticket_data);
            # verify_ticket strips !tfa! prefix, so we expect waLogin! prefix now
            die "invalid challenge ticket\n" unless $ticket_data =~ s/^waLogin!//;
            my $challenge = $ticket_data;

            # Get TFA config and configure WebAuthn
            my $tfa_cfg = cfs_read_file('priv/tfa.cfg');
            PVE::AccessControl::configure_u2f_and_wa($tfa_cfg);

            # Verify the WebAuthn response
            my $tfa_response = "webauthn:" . $param->{response};
            my $result = $tfa_cfg->authentication_verify2(
                $username, $challenge, $tfa_response
            );

            die "WebAuthn verification failed\n" unless $result->{result};

            # Save TFA state if needed (e.g., counter update)
            if ($result->{'needs-saving'}) {
                cfs_write_file('priv/tfa.cfg', $tfa_cfg);
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
