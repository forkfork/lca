import unittest
from unittest.mock import patch,Mock
from aws_cli import _resolve
class CLITests(unittest.TestCase):
 def setUp(self):_resolve.cache_clear()
 def test_stale_config_uses_persistent_install_without_network(self):
  with patch('aws_cli.shutil.which',side_effect=[None,'/persistent/aws']),patch('aws_cli.subprocess.run',return_value=Mock(returncode=0)) as run:
   self.assertEqual(_resolve('/tmp/gone','path','data'),'/persistent/aws')
   self.assertEqual(run.call_args.args[0][-2:],['--generate-cli-skeleton','input'])
 def test_old_cli_falls_back_to_compatible_one(self):
  with patch('aws_cli.shutil.which',side_effect=['/old/aws','/new/aws']),patch('aws_cli.subprocess.run',side_effect=[Mock(returncode=252),Mock(returncode=0)]):
   self.assertEqual(_resolve('/old/aws','path','data'),'/new/aws')
 def test_missing_and_outdated_errors_are_actionable(self):
  with patch('aws_cli.shutil.which',return_value=None):
   with self.assertRaisesRegex(FileNotFoundError,'local LCA still works'):_resolve(None,'','data')
  with patch('aws_cli.shutil.which',return_value='/old/aws'),patch('aws_cli.subprocess.run',return_value=Mock(returncode=252)):
   with self.assertRaisesRegex(RuntimeError,'Update AWS CLI'):_resolve(None,'','data')
