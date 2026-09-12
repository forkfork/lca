import unittest
from unittest.mock import patch
from storage_setup import setup
class SetupTests(unittest.TestCase):
 def test_explicit_bucket_requires_no_setup(self):
  with patch('storage_setup.api') as api,patch('storage_setup.s3') as s3:
   cfg={'checkpoint_bucket':'existing'};self.assertEqual(setup(cfg),cfg)
   api.assert_not_called();s3.assert_not_called()
 def test_missing_bucket_provisioned_with_scoped_policy(self):
  calls=[]
  def s3(cfg,op,*args):
   calls.append((op,args))
   if op=='head-bucket' and len(calls)==1:raise RuntimeError('404')
   return {}
  with patch('storage_setup.api',side_effect=[{'Account':'123456789012'},{}]) as api,patch('storage_setup.s3',side_effect=s3),patch('storage_setup.ensure') as ensure:
   result=setup({'execution_role_arn':'arn:aws:iam::123456789012:role/run'})
   self.assertEqual(result['checkpoint_bucket'],'lca-recovery-123456789012-ap-southeast-2')
   self.assertIn('create-bucket',[x[0] for x in calls]);ensure.assert_called_once()
   policy=api.call_args.args[-1]
   self.assertIn('/recovery/*/snapshots/*',policy);self.assertNotIn('s3:*',policy)
 def test_forbidden_bucket_not_claimed(self):
  with patch('storage_setup.api',return_value={'Account':'123456789012'}),patch('storage_setup.s3',side_effect=RuntimeError('403')) as s3:
   with self.assertRaises(RuntimeError):setup({})
   self.assertEqual(s3.call_count,1)
