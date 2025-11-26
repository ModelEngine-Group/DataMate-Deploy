#!/usr/bin/env python3

import argparse
import json
import logging
import os
import shlex
import signal
import subprocess
import time

# CONSTANTS
CLUSTER_INFO_SMARTKUBE = "cluster-info-smartkube"
CLUSTER_INFO_NAMESPACE = "kube-system"

SECTION_BEGIN = "# section-datamate-%s-begin"
SECTION_END = "# section-datamate-%s-end"

LOG_PATH = "install.log"
LOG_FORMAT = "[%(asctime)s] [%(levelname)s] [%(process)d] [%(threadName)s] " \
             "[%(filename)s %(lineno)d] [%(funcName)s] %(message)s"


def get_logger(logfile, name=None, level=logging.INFO, device='file'):
    """init log module
    Params:
        :param logfile: log file path
        :param name: logger name
        :param level: level in logging
        :param device: file or console
    """
    if device == 'console':
        handler = logging.StreamHandler()
    else:
        handler = logging.FileHandler(logfile)
    handler.setFormatter(logging.Formatter(LOG_FORMAT))
    _logger = logging.getLogger(name)
    _logger.setLevel(level)
    _logger.addHandler(handler)
    return _logger


logger = get_logger(LOG_PATH)


class ConfigMapOperator(object):
    @staticmethod
    def dump(namespace, name, out_path):
        cmd = f"kubectl get configmap {name} -n {namespace} -o json"
        code, _ = run_shell_cmd_with_file_handler(cmd, out_file=out_path)
        if code == 0:
            logger.info("dump config map success: %s", name)
            return True
        logger.error("dump config map failed: %s", name)
        return False

    @staticmethod
    def replace(in_path):
        cmd = f"kubectl replace -f {in_path}"
        code, _ = run_shell_cmd(cmd)
        if code == 0:
            logger.info("update config map success: %s", in_path)
            return True
        logger.error("update config map failed: %s", in_path)
        return False


class ClusterInfoOperator(object):
    def __init__(self, work_dir=None):
        self._work_dir = work_dir if work_dir else os.getcwd()
        self._ori_path = os.path.join(self._work_dir, "cluster_info_smart_kube_ori.json")
        self._new_path = os.path.join(self._work_dir, "cluster_info_smart_kube_new.json")

    def dump(self):
        return ConfigMapOperator.dump(CLUSTER_INFO_NAMESPACE, CLUSTER_INFO_SMARTKUBE, self._ori_path)

    def replace(self):
        return ConfigMapOperator.replace(self._new_path)

    def get_json_data(self):
        try:
            with open(self._ori_path, mode='r') as f:
                config_data = json.load(f)
                return config_data
        except OSError:
            logger.error(f"open {self._ori_path} failed.")
            return None

    def update_haproxy_data(self, namespace, current_haproxy, front_ip, front_port, backend_ip, backend_port,
                            address_type):
        # 将当前配置分割成行
        lines = current_haproxy.splitlines()
        updated_lines = []
        i = 0
        matched = False

        section_begin = SECTION_BEGIN % namespace
        section_end = SECTION_END % namespace

        while i < len(lines):
            line = lines[i].rstrip()

            if section_begin in line:
                matched = True
                i += 1
                continue
            if section_end in line:
                matched = False
                i += 1
                continue

            if matched:
                i += 1
                continue

            # 保留其他行
            updated_lines.append(line)
            i += 1

        # 检查最后一行是否需要添加空行
        if updated_lines and updated_lines[-1].strip():
            updated_lines.append('')

        # 添加新配置到文件末尾
        logger.info(f'在文件末尾添加新的配置')
        if address_type == "management":
            updated_lines.extend([
                f"{section_begin}",
                f"frontend {namespace}_datamate_frontend",
                f"    bind {front_ip}:{front_port} interface {{{{.ApisvrFrontIF}}}}",
                f"    default_backend   {namespace}_datamate_backend",
                f"    maxconn {{{{.ApisvrFrontMaxConn}}}}",
                f"    mode tcp",
                "",
                f"backend {namespace}_datamate_backend",
                f"    default-server inter 2s downinter 5s rise 2 fall 2 slowstart 60s maxconn 2000 maxqueue"
                f" 200 weight 100",
                f"    balance   roundrobin",
                f"    server app0 {backend_ip}:{backend_port}",
                f"    mode tcp",
                f"{section_end}",
            ])
        else:
            updated_lines.extend([
                f"{section_begin}",
                f"frontend {namespace}_datamate_frontend",
                f"    bind {front_ip}:{front_port} interface {{{{.TraefikFrontIF}}}}",
                f"    default_backend   {namespace}_datamate_backend",
                f"    maxconn {{{{.ApisvrFrontMaxConn}}}}",
                f"    mode tcp",
                "",
                f"backend {namespace}_datamate_backend",
                f"    default-server inter 2s downinter 5s rise 2 fall 2 slowstart 60s maxconn 2000 maxqueue"
                f" 200 weight 100",
                f"    balance   roundrobin",
                f"    server app0 {backend_ip}:{backend_port}",
                f"    mode tcp",
                f"{section_end}",
            ])

        # 构造新的配置内容
        new_haproxy_content = '\n'.join(updated_lines)
        return new_haproxy_content

    def update(self, namespace, front_ip, front_port, backend_ip, backend_port, address_type):
        if not self.dump():
            logger.error("dump cluster info failed.")
            return False
        config_data = self.get_json_data()

        # 获取当前的 haproxy 配置数据
        if 'data' not in config_data or 'haproxy' not in config_data['data']:
            raise Exception('Cannot find haproxy config item')
        current_haproxy = config_data['data']['haproxy']

        # 更新 haproxy 配置数据
        new_haproxy_content = self.update_haproxy_data(namespace, current_haproxy, front_ip, front_port, backend_ip,
                                                       backend_port, address_type)

        # 更新配置数据
        config_data['data']['haproxy'] = new_haproxy_content

        with open(self._new_path, mode='w') as f_new:
            json.dump(config_data, f_new)

        if not self.replace():
            logger.error("replace cluster info failed.")
            return False
        return True


def run_shell_cmd(shell_cmd, time_out=0):
    try:
        cmd = shlex.split(shell_cmd)
        sub_proc = subprocess.Popen(
            cmd,
            stderr=subprocess.STDOUT,
            stdout=subprocess.PIPE,
            shell=False)
        t_beginning = time.time() * 1000
        ret_info = None
        while True:
            time.sleep(0.1)
            if sub_proc.poll() is not None:
                break
            ret_info = sub_proc.communicate()[0].strip()
            seconds_passed = time.time() * 1000 - t_beginning
            if time_out > 0 and seconds_passed > time_out * 1000:
                os.killpg(sub_proc.pid, signal.SIGTERM)
                return -2, 'run command time out'
        if ret_info is None:
            ret_info = sub_proc.communicate()[0].strip()

        if ret_info is not None and isinstance(ret_info, bytes):
            ret_info = bytes.decode(ret_info)

        return sub_proc.returncode, ret_info
    except Exception as exp:
        return -1, "Run cmd exception:%s" % exp


def run_shell_cmd_with_file_handler(shell_cmd, out_file, time_out=0):
    with open(out_file, mode='w') as file_handler:
        try:
            cmd = shlex.split(shell_cmd)
            sub_proc = subprocess.Popen(
                cmd,
                stderr=subprocess.STDOUT,
                stdout=file_handler,
                shell=False)
            t_beginning = time.time() * 1000
            while True:
                time.sleep(0.1)
                if sub_proc.poll() is not None:
                    break
                seconds_passed = time.time() * 1000 - t_beginning
                if time_out > 0 and seconds_passed > time_out * 1000:
                    os.killpg(sub_proc.pid, signal.SIGTERM)
                    return -2, 'run command time out'

            return sub_proc.returncode, ""
        except Exception as exp:
            return -1, "Run cmd exception:%s" % exp


def parse_args():
    parser = argparse.ArgumentParser(description="Used in ECONTAINER scenario. To update forwarding rules for datamate "
                                                 "in haproxy by rewrite config map named 'cluster-info-smartkube' "
                                                 "in kube-system namespace")
    # Create a subparsers object
    subparsers = parser.add_subparsers(dest='command', required=True)

    parser_update = subparsers.add_parser('update', help='Update an existing rule embraced by '
                                                         '# datamate-rule-<namespace>-begin and '
                                                         '# datamate-rule-<namespace>-end ')
    for parser_obj in (parser_update,):
        parser_obj.add_argument('-n', '--namespace', required=True, help='Namespace to add the rule in')
        parser_obj.add_argument('-f', '--frontend-ip', dest="frontend_ip", required=True, help='Frontend ip')
        parser_obj.add_argument('-p', '--frontend-port', dest="frontend_port", required=True, type=int,
                                help='Frontend port')
        parser_obj.add_argument('-b', '--backend-ip', dest="backend_ip", required=True, help='nginx service ip')
        parser_obj.add_argument('-P', '--backend-port', dest="backend_port", default=80, type=int,
                                help='nginx service port')
        parser_obj.add_argument('-a', '--address-type', dest="address_type", default="management", type=str,
                                help='use management id or business ip')

    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    operator = ClusterInfoOperator()
    if args.command == 'update':
        operator.update(args.namespace, args.frontend_ip, args.frontend_port, args.backend_ip, args.backend_port,
                        address_type=args.address_type)
    else:
        print("Illegal command!")
