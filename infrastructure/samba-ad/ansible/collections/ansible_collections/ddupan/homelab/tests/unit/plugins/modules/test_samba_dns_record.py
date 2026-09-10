import unittest

from ansible_collections.ddupan.homelab.plugins.modules import samba_dns_record


class ParseQueryTests(unittest.TestCase):
    def test_parses_a_records_and_ignores_other_types(self):
        output = """  Name=host, Records=3, Children=0
    A: 192.168.10.4 (flags=f0, serial=1, ttl=900)
    A: 192.168.10.7 (flags=f0, serial=2, ttl=900)
    TXT: ignored (flags=f0, serial=3, ttl=900)
"""
        self.assertEqual(
            samba_dns_record.parse_query(output, "A"),
            ["192.168.10.4", "192.168.10.7"],
        )

    def test_normalizes_dns_targets(self):
        output = "    CNAME: Gateway.AD.DDUPAN.TOP. (flags=f0, serial=1, ttl=900)\n"
        self.assertEqual(
            samba_dns_record.parse_query(output, "CNAME"),
            ["gateway.ad.ddupan.top"],
        )
