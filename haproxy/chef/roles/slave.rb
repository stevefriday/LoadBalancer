name "slave"
description "Haproxy load-Balancer"
run_list(
        "recipe[haproxy::ip_nonlocal_bind]",
        "recipe[haproxy::install]"
)
default_attributes()
override_attributes()
