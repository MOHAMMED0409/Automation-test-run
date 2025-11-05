USE prod-sso;
UPDATE prod_sso
SET 
  user_name = CONCAT('user_', LPAD(id, 4, '0')),
  email = CONCAT('user_', LPAD(id, 4, '0'), '@anonymized.local');