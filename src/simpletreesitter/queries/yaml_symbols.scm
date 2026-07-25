; 文档顶层映射键（大纲导航用）
(document
  (block_node
    (block_mapping
      (block_mapping_pair
        key: (flow_node (plain_scalar (string_scalar) @symbol.property))))))

; 二级映射键
(document
  (block_node
    (block_mapping
      (block_mapping_pair
        value: (block_node
          (block_mapping
            (block_mapping_pair
              key: (flow_node (plain_scalar (string_scalar) @symbol.field)))))))))
