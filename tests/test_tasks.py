import copy
import unittest

from tools.validate_tasks import load, validate_catalog


class TaskCatalogTests(unittest.TestCase):
    def setUp(self):
        self.catalog = load('data/tasks/catalog.json')
        self.solutions = load('backend/data/task-solutions.json')

    def test_seed_bank_is_valid(self):
        self.assertEqual(validate_catalog(self.catalog, self.solutions), [])

    def test_reference_answers_cannot_be_added_to_public_tasks(self):
        self.catalog['tasks'][0]['answer'] = '7'
        self.assertTrue(validate_catalog(self.catalog, self.solutions))

    def test_orphan_and_missing_solutions_are_rejected(self):
        self.solutions['solutions'][0]['task_id'] = 'missing-task'
        self.assertTrue(validate_catalog(self.catalog, self.solutions))

    def test_duplicate_task_ids_are_rejected(self):
        self.catalog['tasks'].append(copy.deepcopy(self.catalog['tasks'][0]))
        self.assertTrue(validate_catalog(self.catalog, self.solutions))

    def test_untranslated_statements_are_rejected(self):
        self.catalog['tasks'][0]['statement']['en'] = ''
        self.assertTrue(validate_catalog(self.catalog, self.solutions))

    def test_unknown_subjects_are_rejected(self):
        self.catalog['tasks'][0]['subject'] = 'missing-subject'
        self.assertTrue(validate_catalog(self.catalog, self.solutions))

    def test_missing_and_unsafe_image_paths_are_rejected(self):
        self.catalog['tasks'][0]['illustrations'] = [{'src':'assets/tasks/missing.svg','alt':{'ru':'Чертёж','en':'Diagram'}}]
        self.assertTrue(validate_catalog(self.catalog, self.solutions))
        self.catalog['tasks'][0]['illustrations'][0]['src'] = '../backend/data/task-solutions.json'
        self.assertTrue(validate_catalog(self.catalog, self.solutions))

    def test_proof_cannot_be_marked_as_a_symbolic_certification(self):
        proof = next(solution for solution in self.solutions['solutions'] if solution['answer']['kind'] == 'proof')
        proof['method'] = 'sympy'
        self.assertTrue(validate_catalog(self.catalog, self.solutions))


if __name__ == '__main__':
    unittest.main()
