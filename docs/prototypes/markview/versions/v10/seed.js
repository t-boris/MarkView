DB.seed({
  Research: [{ id: 'markview', title: 'Развитие MarkView', question: 'Как сделать работу с проектной документацией удобнее?' }],
  Node: [
    { id: 'root', researchId: 'markview', parentId: '', title: 'Развитие MarkView' },
    { id: 'navigation', researchId: 'markview', parentId: 'root', title: 'Навигация по проекту' },
    { id: 'research', researchId: 'markview', parentId: 'root', title: 'Исследования' },
    { id: 'sources', researchId: 'markview', parentId: 'research', title: 'Источники и выводы' }
  ],
  Connection: [],
  Practice: [
    { id: 'practice-1', researchId: 'markview', nodeId: 'navigation', title: 'Проверить навигацию на большом репозитории' },
    { id: 'practice-2', researchId: 'markview', nodeId: 'sources', title: 'Указывать источники для выводов' }
  ]
});
