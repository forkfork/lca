import unittest
from unittest.mock import patch
from retention import ensure,RULES

class RetentionTests(unittest.TestCase):
 def test_missing_policy_installed_and_verified(self):
  with patch('retention.s3',side_effect=[RuntimeError('NoSuchLifecycleConfiguration'),{}, {'Rules':RULES}]) as call:
   ensure({},'bucket')
   self.assertEqual(call.call_args_list[1].args[1],'put-bucket-lifecycle-configuration')
 def test_existing_policy_unchanged(self):
  with patch('retention.s3',return_value={'Rules':RULES}) as call:
   ensure({},'bucket');self.assertEqual(call.call_count,1)
 def test_unrelated_rules_preserved(self):
  import json
  other={'ID':'other','Status':'Enabled','Filter':{'Prefix':'other/'},'Expiration':{'Days':90}}
  with patch('retention.s3',side_effect=[{'Rules':[other],'TransitionDefaultMinimumObjectSize':'all_storage_classes_128K'}, {}, {'Rules':[other]+RULES}]) as call:
   ensure({},'bucket')
   args=call.call_args_list[1].args
   self.assertEqual(json.loads(args[args.index('--lifecycle-configuration')+1])['Rules'],[other]+RULES)
   self.assertIn('--transition-default-minimum-object-size',args)
 def test_access_failure_does_not_replace_policy(self):
  with patch('retention.s3',side_effect=RuntimeError('AccessDenied')) as call:
   with self.assertRaises(RuntimeError):ensure({},'bucket')
   self.assertEqual(call.call_count,1)
 def test_failed_verification_reported(self):
  with patch('retention.s3',side_effect=[{}, {}, {}]):
   with self.assertRaisesRegex(RuntimeError,'not confirmed'):ensure({},'bucket')
