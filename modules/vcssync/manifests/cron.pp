# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
class vcssync::cron {
    include vcssync::settings
    include users::vcs2vcs
    include packages::mozilla::py27_mercurial

    vcssync::crontask {
        "run_vcssync.sh":
            ensure          => present,
            minute          => '*',
            process_timeout => 3600,
            cwd             => "${vcssync::settings::cloud_tools_dst}/scripts",
            virtualenv_dir  => "${vcssync::settings::root}",
            user            => "${users::buildduty::username}",
            params          => "-k ${vcssync::settings::secrets_dir}/vcssync-secrets.json -c ../configs/watch_pending.cfg -r us-west-2 -r us-east-1 -l ${vcssync::settings::root}/vcssync.log";
    }
}
