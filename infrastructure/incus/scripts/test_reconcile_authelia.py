import unittest

from reconcile_authelia import merge


class MergeTests(unittest.TestCase):
    def test_preserves_unrelated_state_and_converges(self):
        before = {'configMap': {'identity_providers': {'oidc': {
            'clients': [{'client_id': 'hydra', 'client_secret': 'test-only'}],
            'claims_policies': {'existing': {'id_token': ['email']}},
            'authorization_policies': {'existing': {'default_policy': 'two_factor'}},
        }}}}
        desired = {'clients': [{'client_id': 'incus', 'public': True}],
                   'authorization_policies': {'incus_admin': {'default_policy': 'deny'}}}
        after = merge(before, desired)
        oidc = after['configMap']['identity_providers']['oidc']
        self.assertEqual(oidc['clients'][0], before['configMap']['identity_providers']['oidc']['clients'][0])
        self.assertIn('existing', oidc['claims_policies'])
        self.assertIn('existing', oidc['authorization_policies'])
        self.assertEqual(len(before['configMap']['identity_providers']['oidc']['clients']), 1)
        self.assertEqual(merge(after, desired), after)
        desired['clients'][0]['public'] = False
        self.assertFalse(merge(after, desired)['configMap']['identity_providers']['oidc']['clients'][1]['public'])

    def test_rejects_duplicate_identity(self):
        before = {'configMap': {'identity_providers': {'oidc': {'clients': [{'client_id': 'incus'}, {'client_id': 'incus'}]}}}}
        with self.assertRaises(ValueError):
            merge(before, {'clients': [{'client_id': 'incus'}], 'authorization_policies': {}})


if __name__ == '__main__':
    unittest.main()
