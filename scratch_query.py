import paramiko
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    client.connect('41.32.99.214', username='redtch', password='RRddT@ch')
    stdin, stdout, stderr = client.exec_command("echo 'Connected successfully!'")
    print(stdout.read().decode('utf-8'))
finally:
    client.close()
