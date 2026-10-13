"""Required product gates and retained external npm observations are distinct."""
import copy
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tool/ci'))
from release_npm_termination_receipts import validate_npm_termination
from release_termination_fixtures import termination_fixture


class TerminationReceipts(unittest.TestCase):
    def test_all_target_route_contracts(self):
        for target, platform, arch in [('linux-x64','linux','x64'), ('macos-arm64','darwin','arm64'),
                                       ('windows-x64','win32','x64')]:
            for route in ('local','global','cache'):
                proof = termination_fixture(target, route)
                validate_npm_termination(proof,target,route,['v24.21.0',platform,arch],'11.19.0')
                mutations = [lambda p:p['termination_control']['cases'].pop(),
                             lambda p:p['termination_control']['cases'][0].update(core_terminated=False),
                             lambda p:p['termination_control']['cases'][0].update(streams_equal=1),
                             lambda p:p['termination_control']['cases'][0].update(route_exit=0),
                             lambda p:p['termination_control']['cases'][0].pop('native_helper_terminated')]
                if target != 'windows-x64':
                    mutations += [lambda p:p['termination_control']['cases'][0].update(native_helper_terminated=False),
                                  lambda p:p['termination_control']['cases'][0].update(route_helper_terminated=False)]
                for mutation in mutations:
                    changed = copy.deepcopy(proof)
                    mutation(changed)
                    with self.subTest(target=target,route=route), self.assertRaises((ValueError,KeyError)):
                        validate_npm_termination(changed,target,route,['v24.21.0',platform,arch],'11.19.0')

    def test_npm_version_must_match_pinned_consumer(self):
        proof = termination_fixture('linux-x64', 'cache')
        for version in ('0.0.0', '11.18.0', '999.999.999', 'v11.19.0', None):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_npm_termination(proof, 'linux-x64', 'cache',
                                         ['v24.21.0', 'linux', 'x64'], version)

    def test_cache_group_and_external_failure_cannot_be_forged(self):
        proof = termination_fixture('linux-x64','cache')
        for mutation in [lambda c:c.pop('cache_group_sigint'),
                         lambda c:c['cache_group_sigint'].update(core_terminated=False),
                         lambda c:c['cache_group_sigint'].update(helper_terminated=False),
                         lambda c:c['cache_group_sigint'].update(outer_exit=0),
                         lambda c:c['cache_group_sigint'].update(core_envelope_exit=True),
                         lambda c:c['cache_group_sigint'].update(invocation='selected-cached-shim-supplement'),
                         lambda c:c['outer_npm_pid_observations']['cases'].clear(),
                         lambda c:c['outer_npm_pid_observations']['cases'][0].update(status='PASSED'),
                         lambda c:c.update(invocation='installed-route')]:
            changed = copy.deepcopy(proof)
            mutation(changed['termination_control'])
            with self.assertRaises((ValueError,KeyError)):
                validate_npm_termination(changed,'linux-x64','cache',['v24.21.0','linux','x64'],'11.19.0')
        with self.assertRaises(ValueError):
            validate_npm_termination(proof,'linux-x64','cache',['v24.19.0','linux','x64'],'11.19.0')

    def test_completed_external_observation_status_is_consistent(self):
        proof = termination_fixture('linux-x64','cache')
        boundary = proof['termination_control']['outer_npm_pid_observations']['cases'][0]
        boundary.update(status='PASSED', observation={'outer_exit':2,'stdout_bytes':10,'stderr_bytes':0,
                                                     'core_terminated':True,'streams_equal':True})
        validate_npm_termination(proof,'linux-x64','cache',['v24.21.0','linux','x64'],'11.19.0')
        boundary['observation']['streams_equal'] = False
        with self.assertRaises(ValueError):
            validate_npm_termination(proof,'linux-x64','cache',['v24.21.0','linux','x64'],'11.19.0')
        boundary['status'] = 'FAILED'
        validate_npm_termination(proof,'linux-x64','cache',['v24.21.0','linux','x64'],'11.19.0')


if __name__ == '__main__':
    unittest.main()
