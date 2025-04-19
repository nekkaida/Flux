-- Update timestamp trigger function
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at triggers
CREATE TRIGGER update_users_timestamp
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION update_timestamp();

CREATE TRIGGER update_boards_timestamp
BEFORE UPDATE ON boards
FOR EACH ROW
EXECUTE FUNCTION update_timestamp();

CREATE TRIGGER update_tasks_timestamp
BEFORE UPDATE ON tasks
FOR EACH ROW
EXECUTE FUNCTION update_timestamp();

CREATE TRIGGER update_task_comments_timestamp
BEFORE UPDATE ON task_comments
FOR EACH ROW
EXECUTE FUNCTION update_timestamp();

-- Automatically add owner as a board member with OWNER role
CREATE OR REPLACE FUNCTION add_owner_as_board_member()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO board_members (board_id, user_id, role)
    VALUES (NEW.id, NEW.owner_id, 'OWNER');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER board_owner_membership
AFTER INSERT ON boards
FOR EACH ROW
EXECUTE FUNCTION add_owner_as_board_member();

-- Task history trigger function
CREATE OR REPLACE FUNCTION track_task_changes()
RETURNS TRIGGER AS $$
DECLARE
    change_type VARCHAR(20);
BEGIN
    IF TG_OP = 'INSERT' THEN
        change_type := 'CREATE';
        INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
        VALUES (NEW.id, NEW.created_by, 'task', NULL, NEW.title, change_type);
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        change_type := 'UPDATE';
        
        -- Title change
        IF NEW.title <> OLD.title THEN
            INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
            VALUES (NEW.id, NEW.created_by, 'title', OLD.title, NEW.title, change_type);
        END IF;
        
        -- Description change
        IF COALESCE(NEW.description, '') <> COALESCE(OLD.description, '') THEN
            INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
            VALUES (NEW.id, NEW.created_by, 'description', OLD.description, NEW.description, change_type);
        END IF;
        
        -- Status change
        IF NEW.status <> OLD.status THEN
            INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
            VALUES (NEW.id, NEW.created_by, 'status', OLD.status::TEXT, NEW.status::TEXT, change_type);
        END IF;
        
        -- Priority change
        IF NEW.priority <> OLD.priority THEN
            INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
            VALUES (NEW.id, NEW.created_by, 'priority', OLD.priority::TEXT, NEW.priority::TEXT, change_type);
        END IF;
        
        -- Due date change
        IF NEW.due_date IS DISTINCT FROM OLD.due_date THEN
            INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
            VALUES (NEW.id, NEW.created_by, 'due_date', OLD.due_date::TEXT, NEW.due_date::TEXT, change_type);
        END IF;
        
        -- Assignee change
        IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN
            INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
            VALUES (NEW.id, NEW.created_by, 'assigned_to', OLD.assigned_to::TEXT, NEW.assigned_to::TEXT, change_type);
        END IF;
        
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        change_type := 'DELETE';
        INSERT INTO task_history (task_id, changed_by, field_name, old_value, new_value, change_type)
        VALUES (OLD.id, OLD.created_by, 'task', OLD.title, NULL, change_type);
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER task_history_trigger
AFTER INSERT OR UPDATE OR DELETE ON tasks
FOR EACH ROW
EXECUTE FUNCTION track_task_changes();

-- Create a function for reordering tasks when status changes or new task is inserted
CREATE OR REPLACE FUNCTION reorder_tasks()
RETURNS TRIGGER AS $$
BEGIN
    -- If status changed, adjust positions
    IF TG_OP = 'UPDATE' AND NEW.status <> OLD.status THEN
        -- Decrease positions for all tasks with position > old position in old status
        UPDATE tasks 
        SET position = position - 1 
        WHERE board_id = NEW.board_id 
          AND status = OLD.status 
          AND position > OLD.position;
        
        -- Set new position to max + 1 in new status
        SELECT COALESCE(MAX(position), 0) + 1 INTO NEW.position 
        FROM tasks 
        WHERE board_id = NEW.board_id 
          AND status = NEW.status;
    
    -- For new tasks, set position to max + 1
    ELSIF TG_OP = 'INSERT' THEN
        SELECT COALESCE(MAX(position), 0) + 1 INTO NEW.position 
        FROM tasks 
        WHERE board_id = NEW.board_id 
          AND status = NEW.status;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER task_reorder_trigger
BEFORE INSERT OR UPDATE OF status ON tasks
FOR EACH ROW
EXECUTE FUNCTION reorder_tasks();

-- View for board statistics
CREATE OR REPLACE VIEW board_statistics AS
SELECT 
    b.id AS board_id,
    b.name AS board_name,
    COUNT(t.id) AS total_tasks,
    SUM(CASE WHEN t.status = 'TO_DO' THEN 1 ELSE 0 END) AS todo_count,
    SUM(CASE WHEN t.status = 'IN_PROGRESS' THEN 1 ELSE 0 END) AS in_progress_count,
    SUM(CASE WHEN t.status = 'REVIEW' THEN 1 ELSE 0 END) AS review_count,
    SUM(CASE WHEN t.status = 'DONE' THEN 1 ELSE 0 END) AS done_count,
    SUM(CASE WHEN t.priority = 'URGENT' THEN 1 ELSE 0 END) AS urgent_count,
    SUM(CASE WHEN t.priority = 'HIGH' THEN 1 ELSE 0 END) AS high_priority_count,
    SUM(CASE WHEN t.due_date < NOW() AND t.status <> 'DONE' THEN 1 ELSE 0 END) AS overdue_count,
    COUNT(DISTINCT t.assigned_to) AS assigned_users_count
FROM 
    boards b
LEFT JOIN 
    tasks t ON b.id = t.board_id
GROUP BY 
    b.id, b.name;

-- View for user statistics
CREATE OR REPLACE VIEW user_statistics AS
SELECT 
    u.id AS user_id,
    u.username,
    COUNT(DISTINCT bm.board_id) AS boards_count,
    COUNT(t.id) AS assigned_tasks_count,
    SUM(CASE WHEN t.status = 'TO_DO' THEN 1 ELSE 0 END) AS todo_count,
    SUM(CASE WHEN t.status = 'IN_PROGRESS' THEN 1 ELSE 0 END) AS in_progress_count,
    SUM(CASE WHEN t.status = 'REVIEW' THEN 1 ELSE 0 END) AS review_count,
    SUM(CASE WHEN t.status = 'DONE' THEN 1 ELSE 0 END) AS done_count,
    SUM(CASE WHEN t.due_date < NOW() AND t.status <> 'DONE' THEN 1 ELSE 0 END) AS overdue_count
FROM 
    users u
LEFT JOIN 
    board_members bm ON u.id = bm.user_id
LEFT JOIN 
    tasks t ON u.id = t.assigned_to
GROUP BY 
    u.id, u.username;