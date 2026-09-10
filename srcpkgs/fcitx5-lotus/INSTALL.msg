This package does not automatically install the service into /etc/sv. Run:
  cp -r /usr/share/examples/sv/fcitx5-lotus /etc/sv/fcitx5-lotus.$(whoami)
  ln -s /etc/sv/fcitx5-lotus.$(whoami) /var/service/fcitx5-lotus.$(whoami)
