<?php
/**
 * PHP Yar Server — Bare service（无 package，场景2后端）
 *
 * 验证 grpc2yar 对无 package fullServiceName（"Bare"）的兼容：
 * gRPC path /Bare/Combine → OpenResty → YAR combine() → PHP Bare::combine
 *
 * 独立文件（非 api.php）：一个 Yar_Server 只暴露一个对象的方法集合，
 * Bare service 需独立的 Bare 对象，通过不同 URL 路由（url 配置指向 bare.php）。
 */

class Bare
{
    /**
     * @param int $a
     * @param int $b
     * @return int
     */
    public function combine($a, $b)
    {
        return $a + $b;
    }
}

$server = new Yar_Server(new Bare());
$server->handle();
