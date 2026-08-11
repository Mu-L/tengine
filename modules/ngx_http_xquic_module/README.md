# ngx_http_xquic_module

Tengine ngx_http_xquic_module 主要用于在服务端启用 QUIC/HTTP3 监听服务。

# 编译

ngx_http_xquic_module 编译依赖

依赖库：

* Tongsuo: https://github.com/Tongsuo-Project/Tongsuo
* xquic: https://github.com/alibaba/xquic

## XQUIC 版本兼容性

Tengine 与 XQUIC 的兼容性主要取决于 CID 和默认连接设置等关键公开 C API。
下表中的 API 兼容范围表示相同的函数签名世代；推荐版本是经过 Tengine 构建和
HTTP/3 集成测试验证的组合。未列出的组合不承诺兼容。

| Tengine 版本 | 关键 XQUIC API 兼容范围 | 推荐并验证的 XQUIC 版本 | 说明 |
| --- | --- | --- | --- |
| 3.1.0 | v1.8.0 之前 | v1.6.0 | 使用不带 `xqc_engine_t` 参数的旧式 CID 和连接设置 API；不兼容 v1.8.0 及后续版本。 |
| 3.2.0 及 master | v1.8.0 至 v1.9.5 | v1.9.5 | 使用 engine-scoped CID 和连接设置 API；v1.9.5 是当前打包和 CI 基线。 |

XQUIC v1.8.0 将 `xqc_scid_str`、`xqc_dcid_str` 和
`xqc_server_set_conn_settings` 等接口改为接收 `xqc_engine_t`，这是两代
API 的兼容边界。使用发布包时应优先选择表中的推荐组合；API 兼容不
代表未经测试的版本组合具备完整的运行时兼容性。

```shell
# 下载 Tongsuo，示例中下载 8.4.0 版本
wget -c "https://github.com/Tongsuo-Project/Tongsuo/archive/refs/tags/8.4.0.tar.gz"
tar -xf 8.4.0.tar.gz

# 下载与当前 Tengine API 兼容并经过验证的 xquic 1.9.5
wget -c "https://github.com/alibaba/xquic/archive/refs/tags/v1.9.5.tar.gz"
tar -xf v1.9.5.tar.gz

# 下载 Tengine 3.0.0 以上版本，示例从 master 获取最新版本，也可下载指定版本
git clone git@github.com:alibaba/tengine.git

# 编译 Tongsuo
cd Tongsuo-8.4.0
./config --prefix=/usr/local/babassl
make
make install
export SSL_TYPE_STR="babassl"
export SSL_PATH_STR="${PWD}"
export SSL_INC_PATH_STR="${PWD}/include"
export SSL_LIB_PATH_STR="${PWD}/libssl.a;${PWD}/libcrypto.a"
cd ../../

# 编译 xquic 库
cd xquic-1.9.5/
mkdir -p build; cd build
cmake -DXQC_SUPPORT_SENDMMSG_BUILD=1 -DXQC_ENABLE_BBR2=1 -DXQC_ENABLE_RENO=1 -DSSL_TYPE=${SSL_TYPE_STR} -DSSL_PATH=${SSL_PATH_STR} -DSSL_INC_PATH=${SSL_INC_PATH_STR} -DSSL_LIB_PATH=${SSL_LIB_PATH_STR} ..
make
cp "libxquic.so" /usr/local/lib/
cd ..

# 编译 Tengine
cd tengine

# 注：xquic 依赖 ngx_http_v2_module，需要参数 --with-http_v2_module
./configure \
  --prefix=/usr/local/tengine \
  --sbin-path=sbin/tengine \
  --with-xquic-inc="../xquic-1.9.5/include" \
  --with-xquic-lib="../xquic-1.9.5/build" \
  --with-http_v2_module \
  --without-http_rewrite_module \
  --add-module=modules/ngx_http_xquic_module \
  --with-openssl="../Tongsuo-8.4.0"

make
make install
```

精简示例配置，其中 default-fake-certificate.pem 为可用证书。

```nginx
worker_processes  1;

error_log  logs/error.log debug;

events {
    worker_connections  1024;
}

xquic_log   "pipe:rollback /usr/local/tengine/logs/tengine-xquic.log baknum=10 maxsize=1G interval=1d adjust=600" info;

http {
    xquic_ssl_certificate        /usr/local/tengine/ssl/default-fake-certificate.pem;
    xquic_ssl_certificate_key    /usr/local/tengine/ssl/default-fake-certificate.pem;

    server {
        listen 2443 xquic reuseport;

        location / {
        }
    }
}
```

启动 tengine

```shell
/usr/local/tengine/sbin/tengine -p /usr/local/tengine/ -c conf/tengine.conf
```

启动后 tengine 监听 2443 UDP 端口，此端口可以接收 HTTP3 请求，可以通过编译 xquic 自带的 `test_client` 测试（cmake 编译 xquic 时需要带 `-DXQC_ENABLE_TESTING=1` 参数）

```shell
./test_client -a 127.0.0.1 -p 2443 -u https://domain/
```

更为详细的指令可参考官网文档 [XQUIC模块](https://tengine.taobao.org/document_cn/xquic_cn.html)

# 浏览器使用 HTTP3

**注意：浏览器访问需要确保证书受信。**

浏览器默认不会使用 `HTTP3` 请求，需要服务端响应包头 `Alt-Svc` 进行升级说明，浏览器通过响应包头感知到服务端是支持 `HTTP3` 的，下次请求会尝试使用 `HTTP3`。

```nginx
worker_processes  1;

user root;

error_log  logs/error.log debug;

events {
    worker_connections  1024;
}

xquic_log   "pipe:rollback /usr/local/tengine/logs/tengine-xquic.log baknum=10 maxsize=1G interval=1d adjust=600" info;

http {
    xquic_ssl_certificate        /usr/local/tengine/ssl/default-fake-certificate.pem;
    xquic_ssl_certificate_key    /usr/local/tengine/ssl/default-fake-certificate.pem;

    server {
        listen 2443 xquic reuseport;

        location / {
        }
    }

    server {
        listen 80 default_server reuseport backlog=4096;
        listen 443 default_server reuseport backlog=4096 ssl http2;
        listen 443 default_server reuseport backlog=4096 xquic;

        server_name s1.test.com;

        add_header Alt-Svc 'h3=":443"; ma=2592000,h3-29=":443"; ma=2592000' always;

        ssl_certificate     /etc/ingress-controller/ssl/s1.crt;
        ssl_certificate_key /etc/ingress-controller/ssl/s1.key;
    }

    server {
        listen 80;
        listen 443 ssl http2;
        listen 443 xquic;

        server_name s2.test.com;

        add_header Alt-Svc 'h3=":443"; ma=2592000,h3-29=":443"; ma=2592000' always;

        ssl_certificate     /etc/ingress-controller/ssl/s2.crt;
        ssl_certificate_key /etc/ingress-controller/ssl/s2.key;
    }
}
```

通过以上配置，浏览器访问对应域名，第一次访问 `HTTP2`，下次访问会切换至 `HTTP3`。

**注意**：

在生产环境中，处于安全性考虑，一般情况会以普通用户权限启动 `Tenigne`，而 `xquic` 功能在普通用户权限下，监听端口必须配置为 1024 以上，如监听 2443 端口，那对外的四层负载均衡需要做 443 到 2443 端口的映射，`Tenigne` `Server`段配置示例：

```nginx
    server {
        listen 80 default_server reuseport backlog=4096;
        listen 443 default_server reuseport backlog=4096 ssl http2;
        listen 2443 default_server reuseport backlog=4096 xquic;

        add_header Alt-Svc 'h3=":443"; ma=2592000,h3-29=":443"; ma=2592000' always;

        ssl_certificate     /etc/ingress-controller/ssl/s1.crt;
        ssl_certificate_key /etc/ingress-controller/ssl/s1.key;
    }
```

四层负载均衡配置示例：

```yaml
  type: LoadBalancer
  ports:
  - port: 80
    name: tengine-tcp-80
    protocol: TCP
    targetPort: 80
  - port: 443
    name: tengine-tcp-443
    protocol: TCP
    targetPort: 443
  - port: 443
    name: tengine-udp-443
    protocol: UDP
    targetPort: 2443
  selector:
    app: tengine
```

对用户来讲，还是通过 443 端口访问，通过四层负载均衡设备，转换为 `Tengine` 的 2443 端口。
