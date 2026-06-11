<?php

declare(strict_types=1);

use Testo\Application\Config\ApplicationConfig;
use Testo\Application\Config\FinderConfig;

return new ApplicationConfig(
    src: new FinderConfig(
        include: ['src'],
    ),
    // Suite каждого модуля описаны в его tests/<Module>/suites.php и собираются
    // здесь. Новый модуль — добавить require его suites.php в array_merge ниже.
    suites: \array_merge(
        require __DIR__ . '/tests/Worker/suites.php',
        require __DIR__ . '/tests/KeyValue/suites.php',
    ),
);
