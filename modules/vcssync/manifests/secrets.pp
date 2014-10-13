# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
class aws_manager::secrets {
    include ::config
    include aws_manager::settings
    include users::buildduty

    $builder_passwords = secret("builder_passwords")
    $servo_passwords = secret("servo_passwords")

    file {
        "${aws_manager::settings::secrets_dir}":
            ensure  => directory,
            mode    => 0700,
            owner   => "${users::buildduty::username}",
            group   => "${users::buildduty::group}",
            require => Python::Virtualenv["${aws_manager::settings::root}"];
        "${aws_manager::settings::secrets_dir}/cached_certs":
            ensure  => directory,
            mode    => 0700,
            owner   => "${users::buildduty::username}",
            group   => "${users::buildduty::group}",
            require => Python::Virtualenv["${aws_manager::settings::root}"];
        "${users::buildduty::home}/.boto":
            mode      => 0600,
            owner     => "${users::buildduty::username}",
            group     => "${users::buildduty::group}",
            show_diff => false,
            content   => template("$module_name/dot_boto.erb");
        "${users::buildduty::home}/.ssh/aws-ssh-key":
            mode      => 0600,
            owner     => "${users::buildduty::username}",
            group     => "${users::buildduty::group}",
            show_diff => false,
            content   => secret("aws_manager_ssh_key");
        "${aws_manager::settings::secrets_dir}/aws-secrets.json":
            mode      => 0600,
            owner     => "${users::buildduty::username}",
            group     => "${users::buildduty::group}",
            show_diff => false,
            content   => template("$module_name/aws-secrets.json.erb");
        "${aws_manager::settings::secrets_dir}/aws-secrets-servo.json":
            mode      => 0600,
            owner     => "${users::buildduty::username}",
            group     => "${users::buildduty::group}",
            show_diff => false,
            content   => template("$module_name/aws-secrets-servo.json.erb");
        "${aws_manager::settings::secrets_dir}/passwords.json":
            mode      => 0600,
            owner     => "${users::buildduty::username}",
            group     => "${users::buildduty::group}",
            show_diff => false,
            content   => template("$module_name/passwords.json.erb");
        "${aws_manager::settings::secrets_dir}/passwords-servo.json":
            mode      => 0600,
            owner     => "${users::buildduty::username}",
            group     => "${users::buildduty::group}",
            show_diff => false,
            content   => template("$module_name/passwords-servo.json.erb");
    }
}
