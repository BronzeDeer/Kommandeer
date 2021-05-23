 .[1] as $pv
 | .[0].metadata.generateName = $namePrefix
 | .[0].spec.volumeName = $pv.metadata.name
 | .[0].spec.accessModes = $pv.spec.accessModes
 | .[0].spec.resources.requests.storage = $pv.spec.capacity.storage
 | .[0]
